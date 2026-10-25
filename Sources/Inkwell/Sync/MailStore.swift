import Foundation
import SwiftUI
import AppKit
import Network

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var undoTitle: String? = "Undo"
    var countdown: Int? = nil
    var isError = false
    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id && a.countdown == b.countdown && a.message == b.message }
}

@MainActor
@Observable
final class MailStore {
    static let shared = MailStore()

    var settings: AppSettings { didSet { SettingsStore.save(settings); settingsChanged(oldValue) } }
    var folders: [UUID: [MailFolder]] = [:]
    var mailbox: Mailbox = .allInboxes { didSet { if oldValue != mailbox { keptInUnread = []; selection = []; reload(); syncCurrentFolderIfNeeded() } } }
    var tab: InboxTab = .all { didSet { keptInUnread = []; reload() } }
    var unreadOnly = false {
        didSet {
            keptInUnread = selection
            reload()
            if unreadOnly { syncAll() }
        }
    }
    var threads: [ThreadSummary] = []
    var selection: Set<String> = [] {
        didSet {
            if !selection.isEmpty { focusedThread = nil }
            // Under "Unread", only the open conversation stays listed after being read; the
            // previous one drops out once the user moves on.
            if unreadOnly && selection != keptInUnread {
                let dropped = !keptInUnread.subtracting(selection).isEmpty
                keptInUnread = selection
                if dropped { reload() }
            }
        }
    }
    var focusedThread: ThreadSummary?
    var syncing: Set<UUID> = []
    /// When the last sync finished cleanly (sidebar footer).
    var lastSynced: Date?
    var accountErrors: [UUID: String] = [:]
    var unreadCounts: [UUID: Int] = [:]
    var tabUnread: [InboxTab: Int] = [:]
    var toReplyCount = 0
    var snoozedCount = 0
    var flaggedCount = 0
    var copiedCodes: Set<String> = []
    var toast: Toast?
    var searchPresented = false
    var paletteQuery = ""
    var drafts: [UUID: OutgoingDraft] = [:]
    var openCompose: ((UUID) -> Void)?
    var pendingApproval: PendingSendApproval?

    @ObservationIgnored let db = Database.shared
    @ObservationIgnored var connections: [UUID: AccountConnection] = [:]
    /// Second connection per account for opening emails, so a click never waits behind a
    /// sync on the main one. Opened on demand, closed after a few idle minutes.
    @ObservationIgnored var readers: [UUID: AccountConnection] = [:]
    @ObservationIgnored private var watchers: [UUID: IdleWatcher] = [:]
    @ObservationIgnored var undoHandler: (() -> Void)?
    /// Benchmarks: observes the moment new mail is ready for notifications / the code popup.
    @ObservationIgnored var newMailHook: (([MessageRecord]) -> Void)?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored var pendingSends: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var timers: [Timer] = []
    /// Keeps App Nap from throttling IDLE and sync while the app sits in the background,
    /// so sign-in codes pop up seconds after they arrive.
    @ObservationIgnored private var mailActivity: NSObjectProtocol?
    @ObservationIgnored private var initialSyncDone: Set<UUID> = []
    @ObservationIgnored private var lastFolderList: [UUID: Date] = [:]
    /// Sync requests that arrived while that account was already syncing; replayed when it finishes.
    @ObservationIgnored private var resyncRequested: [UUID: String?] = [:]
    @ObservationIgnored private var lastSyncStarted: [UUID: Date] = [:]
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var lastPath: (status: NWPath.Status, interfaces: [String])?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored var trustedRecipients: [String: Set<String>] = [:]
    @ObservationIgnored private var reloadScheduled = false
    @ObservationIgnored private var reloadGeneration = 0
    /// The thread open while "Unread" is on stays listed after it is marked read, so it doesn't
    /// vanish under the cursor; it drops out when the selection moves. Reset when the filter, mailbox or tab changes.
    @ObservationIgnored private var keptInUnread: Set<String> = []
    /// Accounts whose unread backlog beyond the sync window was fetched this launch.
    @ObservationIgnored private var unreadSynced: Set<UUID> = []
    @ObservationIgnored private var lastCategorySync: [UUID: Date] = [:]

    private init() {
        Perf.mark("MailStore.init")
        settings = SettingsStore.load()
        for a in settings.accounts { folders[a.id] = db.folders(account: a.id) }
        reloadNow()
        Perf.mark("MailStore.init done (first list computed)")
    }

    var accounts: [Account] { settings.accounts.filter(\.enabled) }
    func account(_ id: UUID) -> Account? { settings.accounts.first { $0.id == id } }

    // MARK: lifecycle

    /// Bump when classification / snippet logic changes so stored mail is re-processed once.
    static let contentVersion = 4

    func start() {
        if UserDefaults.standard.integer(forKey: "contentVersion") < MailStore.contentVersion {
            let db = self.db
            Task.detached(priority: .utility) {
                _ = SyncEngine.reprocessStoredBodies(db: db)
                await MainActor.run {
                    UserDefaults.standard.set(MailStore.contentVersion, forKey: "contentVersion")
                    self.reload()
                }
            }
        }
        mailActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Watching for new mail")
        // Debug snapshots render stored mail only: no network, no Keychain access.
        if ProcessInfo.processInfo.environment["INKWELL_SNAPSHOT"] == nil {
            // Only the signed app bundle touches the real Keychain (test binaries never should).
            LegacyMigration.moveDefaultsAndKeychain()
            for a in accounts { startAccount(a) }
        }
        timers.append(Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in Task { @MainActor in self.tick() } })
        // Safety net behind IDLE; cheap when nothing changed thanks to CONDSTORE.
        timers.append(Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in Task { @MainActor in self.syncAll() } })
        timers.append(Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in Task { @MainActor in self.processPendingActions() } })
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in self.reconnectAll(after: 3) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                for a in self.accounts where Date().timeIntervalSince(self.lastSyncStarted[a.id] ?? .distantPast) > 20 { self.sync(accountId: a.id) }
            }
        }
        startPathMonitor()
        tick()
    }

    /// Drops every IMAP connection (they are likely dead after sleep or a network switch),
    /// restarts IDLE and syncs once the network has settled.
    func reconnectAll(after delay: Double) {
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor in
            for c in self.connections.values { c.disconnect() }
            for c in self.readers.values { c.disconnect() }
            for w in self.watchers.values { w.restart() }
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self.syncAll()
        }
    }

    private func startPathMonitor() {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { path in
            let status = path.status
            let interfaces = path.availableInterfaces.map(\.name)
            Task { @MainActor in
                let previous = self.lastPath
                self.lastPath = (status, interfaces)
                guard let previous else { return }
                if status == .satisfied && (previous.status != .satisfied || previous.interfaces != interfaces) {
                    self.reconnectAll(after: 2)
                }
            }
        }
        m.start(queue: DispatchQueue(label: "inkwell.path"))
        pathMonitor = m
    }

    func startAccount(_ a: Account) {
        guard connections[a.id] == nil else { return }
        connections[a.id] = AccountConnection(account: a)
        readers[a.id] = AccountConnection(account: a, label: "imap-read", idleTimeout: 300)
        let w = IdleWatcher(account: a) { [weak self] growth in
            Task { @MainActor in self?.sync(accountId: a.id, inboxOnly: true, expectNew: growth) }
        }
        watchers[a.id] = w
        w.start()
        sync(accountId: a.id)
    }

    func stopAccount(_ id: UUID) {
        watchers[id]?.stop(); watchers[id] = nil
        connections[id]?.disconnect(); connections[id] = nil
        readers[id]?.disconnect(); readers[id] = nil
    }

    private func settingsChanged(_ old: AppSettings) {
        for a in settings.accounts {
            if let o = old.accounts.first(where: { $0.id == a.id }) {
                let serverChanged = o.imapHost != a.imapHost || o.username != a.username || o.imapPort != a.imapPort || o.enabled != a.enabled
                if serverChanged { stopAccount(a.id); if a.enabled { startAccount(a) } }
                else { connections[a.id]?.update(a); readers[a.id]?.update(a) }
            } else if a.enabled { startAccount(a) }
        }
        for o in old.accounts where !settings.accounts.contains(where: { $0.id == o.id }) { stopAccount(o.id) }
        if old.blockedSenders != settings.blockedSenders || old.mutedThreads != settings.mutedThreads { reload() }
    }

    func addAccount(_ a: Account, password: String) {
        Keychain.setPassword(password, for: a)
        settings.accounts.append(a)
    }

    func removeAccount(_ id: UUID) {
        stopAccount(id)
        settings.accounts.removeAll { $0.id == id }
        for m in db.messages(where: "account=?", [id.uuidString], limit: 1_000_000) { db.deleteMessage(id: m.id) }
        db.exec("DELETE FROM folder_state WHERE account=?", [id.uuidString])
        db.exec("DELETE FROM folders WHERE account=?", [id.uuidString])
        Keychain.forget(id)
        Keychain.delete("acct-\(id.uuidString)")
        folders[id] = nil
        if case .accountInbox(let a) = mailbox, a == id { mailbox = .allInboxes }
        reload()
    }

    // MARK: sync

    func lastFolderListReset(_ id: UUID) { lastFolderList[id] = nil; sync(accountId: id) }

    func syncAll() { for a in accounts { sync(accountId: a.id) } }

    func sync(accountId: UUID, extraFolder: String? = nil, inboxOnly: Bool = false, expectNew: Int? = nil) {
        guard let conn = connections[accountId], var acct = account(accountId) else { return }
        if syncing.contains(accountId) {
            // An IDLE event during a sync may announce mail that sync already missed; run again after.
            if let extraFolder { resyncRequested[accountId] = .some(extraFolder) }
            else if resyncRequested[accountId] == nil { resyncRequested[accountId] = .some(nil) }
            return
        }
        syncing.insert(accountId)
        lastSyncStarted[accountId] = Date()
        let needList = !inboxOnly && (lastFolderList[accountId].map { Date().timeIntervalSince($0) > 600 } ?? true) || (folders[accountId]?.isEmpty ?? true)
        let listFirst = folders[accountId]?.isEmpty ?? true
        let db = self.db
        let isInitial = !initialSyncDone.contains(accountId) && db.folderState(accountId, "INBOX") == nil
        let syncUnread = !unreadSynced.contains(accountId) || (unreadOnly && !inboxOnly)
        // Gmail's tabs for the whole inbox: at launch, then every 10 minutes (new mail gets its tab as it arrives).
        let syncCategories = !inboxOnly && Date().timeIntervalSince(lastCategorySync[accountId] ?? .distantPast) > 600
        Task {
            do {
                let (updatedAcct, listed) = try await conn.run { c -> (Account, [MailFolder]?) in
                    var listed: [MailFolder]? = nil
                    // With folders cached, refresh the list after the inbox instead of before it.
                    if needList && listFirst { listed = try SyncEngine.syncFolders(c, account: &acct, db: db) }
                    let inboxAcct = acct
                    // New inbox mail is announced the moment it's stored; flag refresh, the unread
                    // backlog and Sent continue on this connection meanwhile.
                    try SyncEngine.syncFolder(c, account: acct, path: "INBOX", db: db, expectNew: expectNew,
                                              onHeaders: { Task { @MainActor in self.reload() } },
                                              onNew: { msgs in Task { @MainActor in
                                                  await self.handleNewMail(msgs, account: inboxAcct, initial: isInitial)
                                                  self.reload()
                                              } })
                    if needList && !listFirst { listed = try SyncEngine.syncFolders(c, account: &acct, db: db) }
                    if syncUnread {
                        try SyncEngine.syncUnread(c, account: acct, path: "INBOX", db: db, selected: c.selected == "INBOX" ? c.selectInfo : nil)
                    }
                    if syncCategories { try SyncEngine.syncGmailCategories(c, account: acct, db: db) }
                    if !inboxOnly, let sent = acct.sentFolder { try SyncEngine.syncFolder(c, account: acct, path: sent, db: db, initialLimit: 200) }
                    if let extra = extraFolder, extra != "INBOX", extra != acct.sentFolder {
                        try SyncEngine.syncFolder(c, account: acct, path: extra, db: db, initialLimit: 200)
                    }
                    return (acct, listed)
                }
                if let listed {
                    folders[accountId] = listed
                    lastFolderList[accountId] = Date()
                    if let i = settings.accounts.firstIndex(where: { $0.id == accountId }) {
                        let cur = settings.accounts[i]
                        if cur.sentFolder != updatedAcct.sentFolder || cur.archiveFolder != updatedAcct.archiveFolder || cur.trashFolder != updatedAcct.trashFolder || cur.draftsFolder != updatedAcct.draftsFolder || cur.spamFolder != updatedAcct.spamFolder {
                            settings.accounts[i].sentFolder = updatedAcct.sentFolder
                            settings.accounts[i].archiveFolder = updatedAcct.archiveFolder
                            settings.accounts[i].trashFolder = updatedAcct.trashFolder
                            settings.accounts[i].draftsFolder = updatedAcct.draftsFolder
                            settings.accounts[i].spamFolder = updatedAcct.spamFolder
                        }
                    }
                }
                accountErrors[accountId] = nil
                syncing.remove(accountId)
                lastSynced = Date()
                initialSyncDone.insert(accountId)
                if syncUnread { unreadSynced.insert(accountId) }
                if syncCategories { lastCategorySync[accountId] = Date() }
                reload()
            } catch {
                accountErrors[accountId] = error.localizedDescription
                syncing.remove(accountId)
                reload()
            }
            if let pending = resyncRequested.removeValue(forKey: accountId) { sync(accountId: accountId, extraFolder: pending) }
        }
    }

    private func syncCurrentFolderIfNeeded() {
        if case .folder(let a, let p) = mailbox { sync(accountId: a, extraFolder: p) }
        if case .allRole(let role) = mailbox, role != .sent {
            for a in accounts {
                if let p = role == .spam ? a.spamFolder : a.trashFolder { sync(accountId: a.id, extraFolder: p) }
            }
        }
    }

    /// Rules, blocked senders, muted threads, notifications.
    private func handleNewMail(_ msgs: [MessageRecord], account: Account, initial: Bool) async {
        guard !msgs.isEmpty else { return }
        newMailHook?(msgs)
        var toArchive: [MessageRecord] = [], toTrash: [MessageRecord] = [], toRead: [MessageRecord] = []
        var toMove: [String: [MessageRecord]] = [:]
        var notify: [MessageRecord] = []
        let blocked = Set(settings.blockedSenders.map { $0.lowercased() })
        for m in msgs {
            if blocked.contains(m.from.email.lowercased()) || blocked.contains("@" + m.from.domain) { toTrash.append(m); continue }
            if settings.mutedThreads.contains(m.threadKey) { toRead.append(m); toArchive.append(m); continue }
            var handled = false
            let needsBody = settings.rules.contains { $0.enabled && $0.field == .body }
            let body = needsBody ? (db.raw(for: m.id).map { MIME.parse($0).plainText } ?? m.snippet) : m.snippet
            for r in settings.rules where r.enabled && (r.accountId == nil || r.accountId == account.id) && r.matches(m, body: body) {
                switch r.action {
                case .archive: toArchive.append(m); handled = true
                case .trash: toTrash.append(m); handled = true
                case .markRead: toRead.append(m)
                case .move: if !r.targetFolder.isEmpty { toMove[r.targetFolder, default: []].append(m); handled = true }
                }
                if handled { break }
            }
            if !handled && !m.seen && !m.isFromMe && !initial { notify.append(m) }
        }
        if !toRead.isEmpty { await setSeen(toRead, true, record: false) }
        if !toArchive.isEmpty, let dest = account.archiveFolder { await move(toArchive, to: dest, label: nil) }
        if !toTrash.isEmpty, let dest = account.trashFolder { await move(toTrash, to: dest, label: nil) }
        for (dest, ms) in toMove { await move(ms, to: dest, label: nil) }
        if account.notify && settings.notificationsEnabled {
            for m in notify.prefix(5) { Notifier.shared.notifyNewMail(m, account: account) }
            if !notify.isEmpty {
                CodePopup.shared.show(newMail: notify)
                let signIn = notify.contains { $0.category != .promos && Notifier.signIn(for: $0) != nil }
                Sounds.play(signIn ? .success : .notification)
            }
        }
    }

    // MARK: thread loading

    var accountIdsSQL: String { accounts.map { "'\($0.id.uuidString)'" }.joined(separator: ",") }

    /// Inputs for a thread-list query, captured on the main actor.
    struct ListQuery: Sendable {
        var accountIds: String
        var mailbox: Mailbox
        var tab: InboxTab
        var unreadOnly: Bool
        var blocked: Set<String>
        var muted: Set<String>
        var roleFolders: [FolderRole: [(String, String)]] = [:]   // role → [(account uuid, folder path)]
        var keep: Set<String> = []
    }

    struct ListResult: Sendable {
        var threads: [ThreadSummary]
        var inboxThreads: [ThreadSummary]
        var toReplyCount: Int
        var snoozedCount: Int
        var flaggedCount: Int
        var unreadCounts: [UUID: Int]
        var tabUnread: [InboxTab: Int]
    }

    private var listQuery: ListQuery {
        var roles: [FolderRole: [(String, String)]] = [:]
        for a in accounts {
            if let p = a.sentFolder { roles[.sent, default: []].append((a.id.uuidString, p)) }
            if let p = a.spamFolder { roles[.spam, default: []].append((a.id.uuidString, p)) }
            if let p = a.trashFolder { roles[.trash, default: []].append((a.id.uuidString, p)) }
        }
        return ListQuery(accountIds: accountIdsSQL.isEmpty ? "''" : accountIdsSQL, mailbox: mailbox, tab: tab, unreadOnly: unreadOnly,
                         blocked: Set(settings.blockedSenders.map { $0.lowercased() }), muted: Set(settings.mutedThreads), roleFolders: roles,
                         keep: unreadOnly ? keptInUnread : [])
    }

    /// Coalesces bursts of reload requests (e.g. mute = mark read + archive + settings change)
    /// into one query, and runs the SQL + grouping off the main thread.
    func reload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.reloadScheduled else { return }
            self.reloadScheduled = false
            self.reloadGeneration += 1
            let gen = self.reloadGeneration
            let q = self.listQuery
            let db = self.db
            Task.detached(priority: .userInitiated) {
                let r = MailStore.computeList(q, db: db)
                await MainActor.run {
                    // A newer reload superseded this one (e.g. user switched mailbox again).
                    guard gen == self.reloadGeneration else { return }
                    self.apply(r)
                }
            }
        }
    }

    /// Synchronous variant (startup, benchmarks).
    func reloadNow() {
        reloadScheduled = false
        reloadGeneration += 1
        apply(MailStore.computeList(listQuery, db: db))
    }

    private func apply(_ r: ListResult) {
        toReplyCount = r.toReplyCount
        snoozedCount = r.snoozedCount
        flaggedCount = r.flaggedCount
        if unreadCounts != r.unreadCounts { unreadCounts = r.unreadCounts }
        if tabUnread != r.tabUnread { tabUnread = r.tabUnread }
        let total = r.unreadCounts.values.reduce(0, +)
        NSApp?.dockTile.badgeLabel = total > 0 ? "\(total)" : nil
        WidgetBridge.publish(store: self, inboxThreads: r.inboxThreads)
        // Skipping an identical list spares SwiftUI re-diffing thousands of rows (most syncs change nothing).
        if threads != r.threads { threads = r.threads }
        let ids = Set(r.threads.map(\.id))
        let kept = selection.filter { ids.contains($0) }
        if kept != selection { selection = kept }
    }

    nonisolated static func computeList(_ q: ListQuery, db: Database) -> ListResult {
        let ids = q.accountIds
        let now = Date().timeIntervalSince1970
        let snoozed = Set(db.query("SELECT account, thread_key FROM snoozes WHERE until > ?", [now]) { $0.string(0) + "|" + $0.string(1) })
        let bumps = Dictionary(db.query("SELECT account, thread_key, date FROM bumps") { ($0.string(0) + "|" + $0.string(1), $0.double(2)) }, uniquingKeysWith: max)

        let inboxMsgs = inboxWindow(ids: ids, db: db)
        let inboxThreads = group(inboxMsgs, bumps: bumps).filter { !snoozed.contains($0.id) }
        let replyThreads = toReplyThreads(inboxThreads, muted: q.muted, db: db)

        var unread: [UUID: Int] = [:]
        for t in inboxThreads where t.unread { unread[t.accountId, default: 0] += 1 }

        var list: [ThreadSummary]
        var applyTabs = false
        switch q.mailbox {
        case .allInboxes:
            list = inboxThreads; applyTabs = true
        case .accountInbox(let a):
            list = inboxThreads.filter { $0.accountId == a }; applyTabs = true
        case .toReply:
            list = replyThreads
        case .snoozed:
            let keys = db.query("SELECT account, thread_key FROM snoozes WHERE until > ? ORDER BY until", [now]) { ($0.string(0), $0.string(1)) }
            list = keys.compactMap { threadFromAnyFolder(account: $0.0, key: $0.1, bumps: bumps, db: db) }
        case .reminders:
            let keys = db.query("SELECT account, thread_key FROM reminders ORDER BY until") { ($0.string(0), $0.string(1)) }
            list = keys.compactMap { threadFromAnyFolder(account: $0.0, key: $0.1, bumps: bumps, db: db) }
        case .flagged:
            list = group(db.messages(where: "flagged=1 AND account IN (\(ids))"), bumps: bumps)
        case .scheduled:
            list = []
        case .folder(let a, let p):
            list = group(db.messages(where: "account=? AND folder=?", [a.uuidString, p], limit: 3000), bumps: bumps)
        case .allRole(let role):
            let pairs = q.roleFolders[role] ?? []
            if pairs.isEmpty { list = [] } else {
                let clause = pairs.map { _ in "(account=? AND folder=?)" }.joined(separator: " OR ")
                list = group(db.messages(where: clause, pairs.flatMap { [$0.0, $0.1] as [Any?] }, limit: 3000), bumps: bumps)
            }
        }
        if !q.blocked.isEmpty { list = list.filter { !q.blocked.contains($0.latest.from.email.lowercased()) || $0.latest.isFromMe } }

        var tu: [InboxTab: Int] = [:]
        if applyTabs {
            for t in list where t.unread {
                tu[.all, default: 0] += 1
                let cat = primaryCategory(t)
                tu[cat == .primary ? .primary : cat == .updates ? .updates : .promos, default: 0] += 1
            }
            if let cat = q.tab.category { list = list.filter { primaryCategory($0) == cat } }
        }
        if q.unreadOnly { list = list.filter { $0.unread || q.keep.contains($0.id) } }
        let flagged = db.query("SELECT COUNT(DISTINCT account || thread_key) FROM messages WHERE flagged=1 AND account IN (\(ids))") { $0.int(0) }.first ?? 0
        return ListResult(threads: list, inboxThreads: inboxThreads, toReplyCount: replyThreads.count, snoozedCount: snoozed.count,
                          flaggedCount: flagged, unreadCounts: unread, tabUnread: tu)
    }

    /// The inbox rows the list is built from: the newest 5,000 of *each* account (one busy
    /// account must not push another out of view) plus every unread one, so unread counts and
    /// the Unread filter see all of them.
    nonisolated static func inboxWindow(ids: String, db: Database) -> [MessageRecord] {
        var seen = Set<String>()
        var rows: [MessageRecord] = []
        for id in ids.split(separator: ",") {
            for m in db.messagesCached(where: "folder='INBOX' AND account=\(id)", limit: 5000) where seen.insert(m.id).inserted { rows.append(m) }
        }
        for m in db.messagesCached(where: "folder='INBOX' AND seen=0 AND account IN (\(ids))", limit: 50_000) where seen.insert(m.id).inserted { rows.append(m) }
        rows.sort { $0.date > $1.date }
        return rows
    }

    nonisolated static func primaryCategory(_ t: ThreadSummary) -> MailCategory {
        if t.messages.contains(where: { $0.category == .primary && !$0.isFromMe }) { return .primary }
        return t.messages.first(where: { !$0.isFromMe })?.category ?? .primary
    }

    func primaryCategory(_ t: ThreadSummary) -> MailCategory { MailStore.primaryCategory(t) }

    nonisolated static func group(_ msgs: [MessageRecord], bumps: [String: Double]) -> [ThreadSummary] {
        // uuidString allocates; cache it per account instead of per message.
        var accountKeys: [UUID: String] = [:]
        func key(_ id: UUID) -> String {
            if let k = accountKeys[id] { return k }
            let k = id.uuidString; accountKeys[id] = k; return k
        }
        // Rows arrive newest-first from SQL, so each bucket is already sorted by date.
        var order: [String] = []
        var dict: [String: [MessageRecord]] = [:]
        dict.reserveCapacity(msgs.count / 2)
        for m in msgs {
            let k = key(m.accountId) + "|" + m.threadKey
            if dict[k] == nil { order.append(k); dict[k] = [m] } else { dict[k]!.append(m) }
        }
        var out: [ThreadSummary] = []
        out.reserveCapacity(order.count)
        for k in order {
            guard let ms = dict[k] else { continue }
            var uniq = ms
            if ms.count > 1 {
                // Dedupe identical Message-IDs (same mail in two folders)
                var seenIds = Set<String>(); uniq = []
                for m in ms where m.messageId.isEmpty || seenIds.insert(m.messageId).inserted { uniq.append(m) }
            }
            guard let latest = uniq.first else { continue }
            let sort = max(latest.date.timeIntervalSince1970, bumps[k] ?? 0)
            out.append(ThreadSummary(accountId: latest.accountId, threadKey: latest.threadKey, latest: latest, messages: uniq, count: uniq.count,
                                     accountKey: key(latest.accountId), sortDate: sort))
        }
        if !bumps.isEmpty { out.sort { $0.sortDate > $1.sortDate } }
        return out
    }

    nonisolated private static func threadFromAnyFolder(account: String, key: String, bumps: [String: Double], db: Database) -> ThreadSummary? {
        group(db.messages(where: "account=? AND thread_key=?", [account, key], limit: 200), bumps: bumps).first
    }

    nonisolated private static func toReplyThreads(_ inbox: [ThreadSummary], muted: Set<String>, db: Database) -> [ThreadSummary] {
        let sent = Dictionary(db.query("SELECT account, thread_key, MAX(date) FROM messages WHERE from_me=1 GROUP BY account, thread_key") {
            ($0.string(0) + "|" + $0.string(1), $0.double(2))
        }, uniquingKeysWith: max)
        return inbox.filter { t in
            guard let lastIn = t.messages.first(where: { !$0.isFromMe }) else { return false }
            guard lastIn.needsReply, !lastIn.answered, !muted.contains(t.threadKey) else { return false }
            return (sent[t.id] ?? 0) < lastIn.date.timeIntervalSince1970
        }
    }

    /// Every message in a conversation (inbox, sent, archive...) oldest first.
    func conversation(_ t: ThreadSummary) -> [MessageRecord] {
        let all = db.messages(where: "account=? AND thread_key=?", [t.accountId.uuidString, t.threadKey], limit: 500)
        var byId: [String: MessageRecord] = [:]
        var out: [MessageRecord] = []
        for m in all.sorted(by: { ($0.folder == "INBOX" ? 0 : 1) < ($1.folder == "INBOX" ? 0 : 1) }) {
            let key = m.messageId.isEmpty ? m.id : m.messageId
            if byId[key] == nil { byId[key] = m; out.append(m) }
        }
        return out.sorted { $0.date < $1.date }
    }

    var selectedThreads: [ThreadSummary] { threads.filter { selection.contains($0.id) } }

    // MARK: body loading

    /// The connection to download an email on: the main one when it's free (already signed in),
    /// otherwise the reader, so opening mail never queues behind a sync.
    func bodyConnection(_ account: UUID) -> AccountConnection? {
        if let main = connections[account], !main.isBusy { return main }
        return readers[account] ?? connections[account]
    }

    func loadBody(_ m: MessageRecord) async -> ParsedMessage? {
        if let raw = db.raw(for: m.id) { return MIME.parse(raw) }
        guard let conn = bodyConnection(m.accountId), let acct = account(m.accountId) else { return nil }
        let db = self.db
        let raw = try? await conn.run { c in try SyncEngine.fetchBody(c, rec: m, account: acct, db: db) }
        return (raw ?? nil).map(MIME.parse)
    }

    /// Loads many bodies at once: cached ones from disk, the rest in one FETCH per folder
    /// (opening a long thread used to cost one SELECT+FETCH round trip per message).
    func loadBodies(_ msgs: [MessageRecord]) async -> [String: ParsedMessage] {
        var out: [String: ParsedMessage] = [:]
        var missing: [MessageRecord] = []
        for m in msgs {
            if let p = parsedCache[m.id] { out[m.id] = p }
            else if let raw = db.raw(for: m.id) { out[m.id] = MIME.parse(raw) } else { missing.append(m) }
        }
        let db = self.db
        for (_, group) in Dictionary(grouping: missing, by: { $0.accountId.uuidString + "|" + $0.folder }) {
            guard let first = group.first, let conn = bodyConnection(first.accountId), let acct = account(first.accountId) else { continue }
            let fetched: [UInt32: Data] = (try? await conn.run { c in
                try c.ensureReadable(first.folder)
                var res: [UInt32: Data] = [:]
                for f in try c.fetch(IMAPClient.uidSet(group.map(\.uid)), items: "UID BODY.PEEK[]") { if let b = f.body { res[f.uid] = b } }
                return res
            }) ?? [:]
            for m in group {
                guard let raw = fetched[m.uid] else { continue }
                SyncEngine.applyBody(raw, to: m, account: acct, db: db)
                out[m.id] = MIME.parse(raw)
            }
        }
        return out
    }

    /// Parsed emails of the conversations next to the open one, so ↑/↓ opens them instantly.
    @ObservationIgnored private var parsedCache: [String: ParsedMessage] = [:]
    @ObservationIgnored private var parsedCacheOrder: [String] = []
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?

    private func cacheParsed(_ p: [String: ParsedMessage]) {
        for (id, v) in p where parsedCache[id] == nil { parsedCache[id] = v; parsedCacheOrder.append(id) }
        while parsedCacheOrder.count > 40 { parsedCache[parsedCacheOrder.removeFirst()] = nil }
    }

    /// After a conversation opens: download (if needed) and parse the next two and previous
    /// one, and lay out the next and previous emails in hidden web views.
    func prefetchNeighbors(of t: ThreadSummary) {
        guard ProcessInfo.processInfo.environment["INKWELL_NO_PREFETCH"] == nil,
              let i = threads.firstIndex(where: { $0.id == t.id }) else { return }
        let order = [i + 1, i - 1, i + 2].filter { threads.indices.contains($0) }.map { threads[$0] }
        prefetchTask?.cancel()
        prefetchTask = Task { @MainActor in
            for (n, nt) in order.enumerated() {
                if Task.isCancelled { return }
                let msgs = conversation(nt)
                let need = msgs.filter { parsedCache[$0.id] == nil }
                if !need.isEmpty { cacheParsed(await loadBodies(need)) }
                guard n < 2, !Task.isCancelled, let last = msgs.last, let p = parsedCache[last.id] else { continue }
                prerender(last, p)
            }
        }
    }

    /// Mirrors what ConversationView shows expanded for the newest message.
    private func prerender(_ m: MessageRecord, _ p: ParsedMessage) {
        let acct = account(m.accountId)
        let isSpam = m.folder == acct?.spamFolder
        let remote = !isSpam && (settings.loadRemoteImages || settings.allowedImageSenders.contains(m.from.email.lowercased()) || m.isFromMe)
        guard !remote else { return }
        let c = HTMLBody.content(p)
        guard (acct?.style ?? .classic) == .classic || c.designed else { return }
        MessageWebView.prerender(id: m.id, html: c.html, designed: c.designed, inline: c.inline)
    }

    // MARK: toast

    func showToast(_ message: String, undo: (() -> Void)? = nil, seconds: Int = 6, isError: Bool = false) {
        toastTask?.cancel()
        undoHandler = undo
        toast = Toast(message: message, undoTitle: undo == nil ? nil : "Undo", isError: isError)
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { self.toast = nil; self.undoHandler = nil }
        }
    }

    func performUndo() {
        let h = undoHandler
        undoHandler = nil
        toast = nil
        toastTask?.cancel()
        h?()
    }

    // MARK: storage

    var storageOptions: StorageManager.Options {
        StorageManager.Options(olderThanMonths: settings.storageMonths, accountIds: [],
                               entireEmails: settings.storageEntireEmails, keepImportant: settings.storageKeepImportant)
    }

    /// Settings → Storage "Clean up automatically": at most once a day, in the background.
    private func autoCleanIfDue() {
        guard settings.storageAutoClean, ProcessInfo.processInfo.environment["INKWELL_SNAPSHOT"] == nil else { return }
        let last = UserDefaults.standard.double(forKey: "storage.lastAutoClean")
        guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "storage.lastAutoClean")
        let (db, opts, ids) = (self.db, storageOptions, settings.accounts.map(\.id))
        Task.detached(priority: .background) {
            let r = StorageManager.cleanUp(db: db, opts, allAccounts: ids)
            if r.emails > 0 { await MainActor.run { self.reload() } }
        }
    }

    // MARK: scheduler

    func tick() {
        let now = Date().timeIntervalSince1970
        var changed = false
        // Snoozes waking up
        let due = db.query("SELECT account, thread_key FROM snoozes WHERE until <= ?", [now]) { ($0.string(0), $0.string(1)) }
        for (acct, key) in due {
            changed = true
            db.exec("DELETE FROM snoozes WHERE account=? AND thread_key=?", [acct, key])
            db.exec("INSERT OR REPLACE INTO bumps(account, thread_key, date) VALUES(?,?,?)", [acct, key, now])
            let msgs = db.messages(where: "account=? AND thread_key=? AND folder='INBOX'", [acct, key], limit: 1)
            if let m = msgs.first {
                Task { await setSeen([m], false, record: false) }
                Notifier.shared.notifySnoozeWake(m)
            }
        }
        // Reminders if no reply
        let reminders = db.query("SELECT account, thread_key, until, sent_date, subject FROM reminders") { ($0.string(0), $0.string(1), $0.double(2), $0.double(3), $0.string(4)) }
        for r in reminders {
            let replies = db.query("SELECT COUNT(*) FROM messages WHERE account=? AND thread_key=? AND from_me=0 AND date > ?", [r.0, r.1, r.3]) { $0.int(0) }.first ?? 0
            if replies > 0 { db.exec("DELETE FROM reminders WHERE account=? AND thread_key=?", [r.0, r.1]); continue }
            if r.2 <= now {
                changed = true
                db.exec("DELETE FROM reminders WHERE account=? AND thread_key=?", [r.0, r.1])
                db.exec("INSERT OR REPLACE INTO bumps(account, thread_key, date) VALUES(?,?,?)", [r.0, r.1, now])
                Notifier.shared.notifyReminder(subject: r.4)
            }
        }
        // Scheduled sends
        let scheduled = db.query("SELECT id, json FROM scheduled WHERE send_at <= ?", [now]) { ($0.string(0), $0.data(1)) }
        for (id, json) in scheduled {
            changed = true
            db.exec("DELETE FROM scheduled WHERE id=?", [id])
            guard let json, var d = try? JSONDecoder().decode(OutgoingDraft.self, from: json) else { continue }
            d.sendAt = nil
            Task {
                do { try await self.deliver(d) }
                catch { self.showToast("Scheduled send failed: \(error.localizedDescription)", isError: true) }
            }
        }
        autoCleanIfDue()
        // Only re-query when something woke up (this runs every 30 s).
        if changed { reload() }
    }
}
