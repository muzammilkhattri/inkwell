import Foundation

/// `INKWELL_HOME=/tmp/x INKWELL_INSECURE_LOCAL=1 Inkwell --recvtest <port>` against
/// `scripts/fake_imap.py <port> <n> 1 <latency>`: runs the real MailStore start-up, IDLE and
/// sync pipeline, injects new mail on the server and times how long until it is ready for the
/// popup (handleNewMail) and visible in the thread list.
@MainActor
enum RecvBench {
    nonisolated static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }

    static func run() -> Never {
        let port = Int(CommandLine.arguments.last ?? "") ?? 1143
        let rounds = Int(ProcessInfo.processInfo.environment["RECV_ROUNDS"] ?? "") ?? 8
        var acct = Account(label: "Test", displayName: "Me", email: "me@example.com", username: "me", imapHost: "127.0.0.1", smtpHost: "127.0.0.1")
        acct.id = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!  // stable, so a re-run reuses the cache
        acct.imapPort = port
        acct.notify = false
        var settings = AppSettings(); settings.accounts = [acct]
        SettingsStore.save(settings)
        Keychain.primeForTesting("x", for: acct)

        let store = MailStore.shared
        var handled: Double?
        store.newMailHook = { _ in if handled == nil { handled = now() } }

        Task { @MainActor in
            func waitUntil(_ timeout: Double = 30, _ cond: () -> Bool) async -> Bool {
                let end = now() + timeout * 1000
                while !cond() { if now() > end { return false }; try? await Task.sleep(for: .milliseconds(1)) }
                return true
            }
            let t0 = now()
            let hadCache = !store.threads.isEmpty
            store.start()
            var sawSync = false
            var firstVisible: Double?, injectedVisible: Double?
            let end = now() + 60_000
            while now() < end {
                if !store.syncing.isEmpty { sawSync = true }
                if firstVisible == nil, !store.threads.isEmpty { firstVisible = now() }
                if injectedVisible == nil, store.threads.contains(where: { $0.latest.subject.contains("sign-in code") }) { injectedVisible = now() }
                if sawSync, store.syncing.isEmpty, firstVisible != nil { break }
                try? await Task.sleep(for: .milliseconds(1))
            }
            let done = now()
            if hadCache {
                print(String(format: "reopen → new mail in list               %8.1f ms", (injectedVisible ?? .nan) - t0))
            } else {
                print(String(format: "first sync → first mail in list         %8.1f ms", (firstVisible ?? .nan) - t0))
            }
            print(String(format: "start → sync complete                   %8.1f ms   %8.1f KB received", done - t0, Double(MailSocket.bytesRead) / 1024))
            if ProcessInfo.processInfo.environment["RECV_OPEN"].map({ !$0.isEmpty }) == true { await openWhileBusy(store) }
            if rounds == 0 { exit(0) }
            try? await Task.sleep(for: .seconds(1.5)) // let IDLE settle

            var ready: [Double] = [], listed: [Double] = []
            for i in 0..<rounds {
                handled = nil
                let before = Set(store.threads.map(\.id))
                let c = try! IMAPClient(host: "127.0.0.1", port: port)
                try! c.login(user: "me", password: "x")
                _ = try! c.command("X-INJECT")
                let tInject = now()
                guard await waitUntil(30, { handled != nil }) else { print("round \(i): timeout"); continue }
                ready.append(handled! - tInject)
                _ = await waitUntil(30) { store.threads.contains { !before.contains($0.id) } }
                listed.append(now() - tInject)
                c.close()
                try? await Task.sleep(for: .milliseconds(1200))
            }
            func stats(_ a: [Double]) -> String {
                let s = a.sorted(); guard !s.isEmpty else { return "n/a" }
                return String(format: "median %7.1f ms   min %7.1f   max %7.1f", s[s.count / 2], s.first!, s.last!)
            }
            if ProcessInfo.processInfo.environment["RECV_GMAIL"].map { !$0.isEmpty } == true {
                let dist = store.db.query("SELECT IFNULL(gm_cat,-1), COUNT(*) FROM messages WHERE folder='INBOX' GROUP BY 1 ORDER BY 1") { "\($0.int(0)):\($0.int(1))" }
                let injected = store.db.query("SELECT IFNULL(gm_cat,-1), category FROM messages WHERE subject LIKE '%sign-in code%'") { "gm=\($0.int(0)) heuristic=\($0.int(1))" }
                let wrong = store.db.query("SELECT COUNT(*) FROM messages WHERE folder='INBOX' AND uid<=2000 AND gm_cat IS NOT (CASE uid % 5 WHEN 0 THEN 2 WHEN 1 THEN 1 WHEN 2 THEN 1 ELSE 0 END)") { $0.int(0) }.first ?? -1
                print("gmail tabs (gm_cat:count, -1 = unknown): \(dist.joined(separator: " "))  mismatches vs server: \(wrong)")
                print("injected mail tabs: \(Set(injected).sorted().joined(separator: ", "))")
            }
            print("new mail → ready for popup            " + stats(ready))
            print("new mail → shown in thread list       " + stats(listed))
            exit(0)
        }
        RunLoop.main.run()
        exit(0)
    }

    /// Opening an email that isn't downloaded while the main connection is busy downloading
    /// (as during a first sync or a body prefetch): old path (main connection) vs `loadBody`.
    static func openWhileBusy(_ store: MailStore) async {
        guard let acct = store.accounts.first, let main = store.connections[acct.id] else { return }
        let db = store.db
        let picks = db.messages(where: "folder='INBOX' AND has_body=1", limit: 12)
        func drop(_ m: MessageRecord) {
            db.exec("DELETE FROM bodies WHERE id=?", [m.id]); db.exec("UPDATE messages SET has_body=0 WHERE id=?", [m.id])
        }
        func busy() -> Task<Void, Never> {
            Task.detached {
                // Four sequential batches, like a sync working through its steps.
                _ = try? await main.run { c in try c.ensureReadable("INBOX"); for k in 0..<4 { _ = try c.fetch("\(k * 100 + 1):\(k * 100 + 100)", items: "UID BODY.PEEK[]") } }
            }
        }
        var old: [Double] = [], new: [Double] = []
        for (i, m) in picks.enumerated() {
            drop(m)
            let b = busy()
            try? await Task.sleep(for: .milliseconds(5))
            let t = now()
            if i % 2 == 0 {
                _ = try? await main.run { c in try SyncEngine.fetchBody(c, rec: m, account: acct, db: db) }
                old.append(now() - t)
            } else {
                _ = await store.loadBody(m)
                new.append(now() - t)
            }
            await b.value
        }
        func med(_ a: [Double]) -> Double { a.sorted()[a.count / 2] }
        print(String(format: "open undownloaded email during sync: main connection %7.1f ms → reader %7.1f ms (median)", med(old), med(new)))
    }
}
