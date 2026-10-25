import Foundation

/// Owns one authenticated IMAP connection for an account and serializes work on it.
final class AccountConnection {
    private(set) var account: Account
    private let queue: DispatchQueue
    private var client: IMAPClient? {
        didSet { liveLock.lock(); live = client; liveLock.unlock() }
    }
    /// Mirror of `client` readable off-queue, so `disconnect()` can interrupt a hung command.
    private var live: IMAPClient?
    private let liveLock = NSLock()

    /// Closes the connection after this long without work (on-demand connections).
    private let idleTimeout: TimeInterval?
    private var generation = 0
    /// Jobs queued or running; readable from any thread.
    private let pendingLock = NSLock()
    private var _pending = 0
    var isBusy: Bool { pendingLock.lock(); defer { pendingLock.unlock() }; return _pending > 0 }

    init(account: Account, label: String = "imap", idleTimeout: TimeInterval? = nil) {
        self.account = account
        self.idleTimeout = idleTimeout
        queue = DispatchQueue(label: "\(label).\(account.id.uuidString)")
    }

    func update(_ a: Account) { queue.async { self.account = a } }

    private func connected() throws -> IMAPClient {
        if let c = client, c.isConnected { return c }
        client?.close()
        let c = try IMAPClient(host: account.imapHost, port: account.imapPort)
        // Nearly every job starts in the inbox; its SELECT rides along with LOGIN.
        try c.login(user: account.username, password: Keychain.password(for: account), select: "INBOX", compress: true)
        client = c
        return c
    }

    func run<T>(_ body: @escaping (IMAPClient) throws -> T) async throws -> T {
        addPending()
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                defer { self.finishedJob() }
                do {
                    let c = try self.connected()
                    cont.resume(returning: try body(c))
                } catch let e as MailError {
                    switch e {
                    case .connection, .closed:
                        // Stale connection: reconnect once and retry.
                        self.client?.close(); self.client = nil
                        do {
                            let c = try self.connected()
                            cont.resume(returning: try body(c))
                        } catch { cont.resume(throwing: error) }
                    default: cont.resume(throwing: e)
                    }
                } catch { cont.resume(throwing: error) }
            }
        }
    }

    private func addPending() { pendingLock.lock(); _pending += 1; pendingLock.unlock() }

    /// Runs on `queue` after each job: on-demand connections hang up once they go quiet.
    private func finishedJob() {
        pendingLock.lock(); _pending -= 1; pendingLock.unlock()
        guard let t = idleTimeout else { return }
        generation += 1
        let g = generation
        queue.asyncAfter(deadline: .now() + t) {
            guard self.generation == g, self.client != nil else { return }
            self.client?.close(); self.client = nil
        }
    }

    /// Interrupts any command in flight (a dead socket would otherwise block the queue forever),
    /// then drops the connection; the next `run` reconnects.
    func disconnect() {
        liveLock.lock(); let c = live; liveLock.unlock()
        c?.abort()
        queue.async { self.client?.close(); self.client = nil }
    }

    static func test(account: Account, password: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                do {
                    let c = try IMAPClient(host: account.imapHost, port: account.imapPort)
                    try c.login(user: account.username, password: password)
                    c.close()
                    let s = try SMTPClient(host: account.smtpHost, port: account.smtpPort, security: account.smtpSecurity)
                    try s.login(user: account.username, password: password)
                    s.quit()
                    cont.resume()
                } catch { cont.resume(throwing: error) }
            }
        }
    }
}

/// Keeps an IDLE connection open on INBOX and calls `onChange` when new mail arrives.
final class IdleWatcher {
    private let account: Account
    private let onChange: (_ newMessages: Int?) -> Void
    private var thread: Thread?
    private let lock = NSLock()
    private var _stopped = false
    private var _client: IMAPClient?
    private let stopper = IdleStopper()
    /// Signalled to cut a reconnect backoff short (wake, network change).
    private let wake = DispatchSemaphore(value: 0)

    private var stopped: Bool { lock.lock(); defer { lock.unlock() }; return _stopped }
    private var client: IMAPClient? {
        get { lock.lock(); defer { lock.unlock() }; return _client }
        set { lock.lock(); _client = newValue; lock.unlock() }
    }

    init(account: Account, onChange: @escaping (_ newMessages: Int?) -> Void) {
        self.account = account
        self.onChange = onChange
    }

    func start() {
        let t = Thread { [weak self] in self?.loop() }
        t.name = "idle.\(account.email)"
        t.start()
        thread = t
    }

    func stop() {
        lock.lock(); _stopped = true; lock.unlock()
        client?.abort()
        wake.signal()
    }

    /// Drops the current IDLE connection and reconnects right away. Used after sleep or a
    /// network change, when the old socket is probably dead but the read hasn't noticed yet.
    func restart() {
        client?.abort()
        wake.signal()
    }

    private func pause(_ seconds: TimeInterval) { _ = wake.wait(timeout: .now() + seconds) }

    private func loop() {
        var backoff: TimeInterval = 5
        var connectedBefore = false
        while !stopped {
            do {
                let c = try IMAPClient(host: account.imapHost, port: account.imapPort)
                client = c
                try c.login(user: account.username, password: Keychain.password(for: account), select: "INBOX", readOnly: true)
                guard c.capabilities.contains("IDLE") else {
                    c.close(); client = nil
                    pause(60)
                    if !stopped { onChange(nil) }
                    continue
                }
                var known = try (c.takeFreshSelect("INBOX", readOnly: true) ?? c.select("INBOX", readOnly: true)).exists
                backoff = 5
                // Mail that arrived while we were disconnected never produced an IDLE event.
                if connectedBefore { onChange(nil) }
                connectedBefore = true
                while !stopped {
                    // Re-issuing IDLE every few minutes keeps NAT/firewall mappings alive and
                    // lets the DONE watchdog notice a dead connection quickly.
                    _ = try c.idle(maxDuration: 8 * 60, stopper: stopper) { exists in
                        // Tell sync how many messages arrived so it can fetch them in one round trip.
                        let growth = exists.map { $0 - known }
                        if let exists { known = exists }
                        self.onChange(growth)
                    }
                }
                c.close(); client = nil
            } catch {
                client?.close(); client = nil
                if stopped { break }
                pause(backoff)
                backoff = min(backoff * 2, 120)
            }
        }
    }
}
