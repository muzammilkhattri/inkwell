import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class Row {
    let stmt: OpaquePointer
    init(_ s: OpaquePointer) { stmt = s }
    func string(_ i: Int32) -> String {
        guard let p = sqlite3_column_text(stmt, i) else { return "" }
        let n = Int(sqlite3_column_bytes(stmt, i))
        return n == 0 ? "" : String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF8.self)
    }
    func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func bool(_ i: Int32) -> Bool { sqlite3_column_int(stmt, i) != 0 }
    func data(_ i: Int32) -> Data? {
        guard let p = sqlite3_column_blob(stmt, i) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
    }
    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
}

final class Database {
    static let shared = Database(path: Paths.database.path)
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    /// Decoded rows by id with the `rev` they were read at (`messagesCached`).
    fileprivate var rowCache: [String: (rev: Int, rec: MessageRecord)] = [:]
    fileprivate let rowCacheLock = NSLock()
    private var statements: [String: OpaquePointer] = [:]

    /// Prepared statements are cached per SQL string (re-preparing dominated small queries).
    private func prepare(_ sql: String) -> OpaquePointer? {
        if let s = statements[sql] { sqlite3_reset(s); sqlite3_clear_bindings(s); return s }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v3(db, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &stmt, nil) == SQLITE_OK else {
            NSLog("SQL prepare error: \(String(cString: sqlite3_errmsg(db))) in \(sql)"); return nil
        }
        statements[sql] = stmt
        return stmt
    }

    init(path: String, readOnly: Bool = false) {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        sqlite3_open_v2(path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil)
        sqlite3_busy_timeout(db, 5000)
        if !readOnly { migrate() }
    }

    private func migrate() {
        exec("PRAGMA journal_mode=WAL")
        exec("""
        CREATE TABLE IF NOT EXISTS messages(
          id TEXT PRIMARY KEY, account TEXT, folder TEXT, uid INTEGER, message_id TEXT, in_reply_to TEXT, refs TEXT,
          thread_key TEXT, from_name TEXT, from_email TEXT, to_json TEXT, cc_json TEXT, reply_to TEXT, subject TEXT,
          date REAL, snippet TEXT, seen INTEGER, flagged INTEGER, answered INTEGER, size INTEGER, category INTEGER,
          needs_reply INTEGER, list_unsub TEXT, list_unsub_post TEXT, has_attach INTEGER, has_body INTEGER, from_me INTEGER,
          attach_names TEXT)
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_msg_folder ON messages(account, folder, uid)")
        exec("CREATE INDEX IF NOT EXISTS idx_msg_thread ON messages(account, thread_key)")
        exec("CREATE INDEX IF NOT EXISTS idx_msg_date ON messages(date)")
        exec("CREATE INDEX IF NOT EXISTS idx_msg_mid ON messages(message_id)")
        exec("CREATE TABLE IF NOT EXISTS bodies(id TEXT PRIMARY KEY, raw BLOB)")
        exec("CREATE VIRTUAL TABLE IF NOT EXISTS msg_fts USING fts5(id UNINDEXED, subject, sender, body, attachments, tokenize='unicode61 remove_diacritics 2')")
        exec("CREATE TABLE IF NOT EXISTS folder_state(account TEXT, path TEXT, uidvalidity INTEGER, last_uid INTEGER, PRIMARY KEY(account, path))")
        exec("CREATE TABLE IF NOT EXISTS folders(account TEXT, path TEXT, name TEXT, role TEXT, delim TEXT, selectable INTEGER, PRIMARY KEY(account, path))")
        exec("CREATE TABLE IF NOT EXISTS snoozes(account TEXT, thread_key TEXT, until REAL, PRIMARY KEY(account, thread_key))")
        exec("CREATE TABLE IF NOT EXISTS bumps(account TEXT, thread_key TEXT, date REAL, PRIMARY KEY(account, thread_key))")
        exec("CREATE TABLE IF NOT EXISTS reminders(account TEXT, thread_key TEXT, until REAL, sent_date REAL, subject TEXT, PRIMARY KEY(account, thread_key))")
        exec("CREATE TABLE IF NOT EXISTS scheduled(id TEXT PRIMARY KEY, json BLOB, send_at REAL)")
        exec("CREATE TABLE IF NOT EXISTS pending_actions(id INTEGER PRIMARY KEY AUTOINCREMENT, app TEXT, json BLOB, created REAL)")
        exec("CREATE TABLE IF NOT EXISTS ai_activity(id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, app TEXT, action TEXT, detail TEXT, undo BLOB, undone INTEGER DEFAULT 0)")
        exec("CREATE TABLE IF NOT EXISTS contacts(email TEXT PRIMARY KEY, name TEXT, count INTEGER, last REAL)")
        // Inbox/folder listing sorted by date, flagged view, and the "did I reply?" lookup.
        exec("CREATE INDEX IF NOT EXISTS idx_msg_folder_date ON messages(folder, date DESC)")
        exec("CREATE INDEX IF NOT EXISTS idx_msg_acct_folder_date ON messages(account, folder, date DESC)")
        exec("CREATE INDEX IF NOT EXISTS idx_msg_flagged ON messages(flagged) WHERE flagged=1")
        exec("CREATE INDEX IF NOT EXISTS idx_msg_fromme ON messages(from_me, account, thread_key, date) WHERE from_me=1")

        let version = query("PRAGMA user_version") { $0.int(0) }.first ?? 0
        if version < 2 {
            // v2: msg_fts rows are addressed by a stable rowid derived from the message id, so
            // updates/deletes are O(log n) instead of a full scan of the UNINDEXED id column.
            transaction {
                exec("DELETE FROM msg_fts")
                for (id, subject, sender, snippet, att) in query("SELECT id, subject, from_name || ' ' || from_email, snippet, attach_names FROM messages", [], {
                    ($0.string(0), $0.string(1), $0.string(2), $0.string(3), $0.string(4))
                }) {
                    exec("INSERT INTO msg_fts(rowid, id, subject, sender, body, attachments) VALUES(?,?,?,?,?,?)", [Database.ftsRowId(id), id, subject, sender, snippet, att])
                }
                exec("PRAGMA user_version=2")
            }
        }
        if version < 3 {
            exec("ALTER TABLE folder_state ADD COLUMN modseq INTEGER DEFAULT 0")
            exec("ALTER TABLE folder_state ADD COLUMN exists_count INTEGER DEFAULT -1")
            exec("PRAGMA user_version=3")
        }
        if version < 4 {
            // v4: Gmail's own tab for the message (0 primary, 1 updates, 2 promos); wins over our heuristic.
            exec("ALTER TABLE messages ADD COLUMN gm_cat INTEGER")
            exec("PRAGMA user_version=4")
        }
        if version < 5 {
            // v5: every insert/update stamps the row with a new `rev`, so the inbox list can reuse
            // rows it already decoded and only re-read the ones that changed.
            // A random 64-bit stamp, so a deleted-then-reinserted row never matches what was
            // cached for it. `upsert` and `exec` set it (a trigger made every upsert ~70% slower).
            exec("ALTER TABLE messages ADD COLUMN rev INTEGER NOT NULL DEFAULT 0")
            exec("PRAGMA user_version=5")
        }
        exec("PRAGMA optimize=0x10002")  // cheap stats refresh instead of a full ANALYZE on every launch
    }

    /// Every `UPDATE messages` also gets a new `rev`, so `messagesCached` sees the change.
    static func stampingRev(_ sql: String) -> String {
        guard sql.hasPrefix("UPDATE messages SET "), !sql.contains("rev=") else { return sql }
        return "UPDATE messages SET rev=random(), " + sql.dropFirst("UPDATE messages SET ".count)
    }

    /// FNV-1a 64-bit hash of the message id, masked to a positive Int64.
    static func ftsRowId(_ id: String) -> Int64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in id.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return Int64(bitPattern: h & 0x7FFF_FFFF_FFFF_FFFF)
    }

    @discardableResult
    func exec(_ sql: String, _ args: [Any?] = []) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let stmt = prepare(Database.stampingRev(sql)) else { return false }
        defer { sqlite3_reset(stmt) }
        bind(stmt, args)
        let rc = sqlite3_step(stmt)
        return rc == SQLITE_DONE || rc == SQLITE_ROW
    }

    /// Runs a write and returns how many rows it changed.
    @discardableResult
    func execChanges(_ sql: String, _ args: [Any?] = []) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard exec(sql, args) else { return 0 }
        return Int(sqlite3_changes(db))
    }

    func query<T>(_ sql: String, _ args: [Any?] = [], _ map: (Row) -> T) -> [T] {
        lock.lock(); defer { lock.unlock() }
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_reset(stmt) }
        bind(stmt, args)
        var out: [T] = []
        let row = Row(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(map(row)) }
        return out
    }

    func transaction(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        exec("BEGIN")
        body()
        exec("COMMIT")
    }

    private func bind(_ stmt: OpaquePointer, _ args: [Any?]) {
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case nil: sqlite3_bind_null(stmt, idx)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as UInt32: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Bool: sqlite3_bind_int(stmt, idx, v ? 1 : 0)
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as Date: sqlite3_bind_double(stmt, idx, v.timeIntervalSince1970)
            case let v as Data: _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
            default: sqlite3_bind_text(stmt, idx, "\(a!)", -1, SQLITE_TRANSIENT)
            }
        }
    }
}

// MARK: - Message persistence

extension Database {
    static let messageColumns = "id, account, folder, uid, message_id, in_reply_to, refs, thread_key, from_name, from_email, to_json, cc_json, reply_to, subject, date, snippet, seen, flagged, answered, size, category, needs_reply, list_unsub, list_unsub_post, has_attach, has_body, from_me, attach_names"
    /// Reads Gmail's tab when known, our own classification otherwise.
    static let selectColumns = messageColumns.replacingOccurrences(of: " category,", with: " COALESCE(gm_cat, category),")
    /// Upsert that leaves `gm_cat` alone, so re-storing a message with its body keeps Gmail's tab.
    static let upsertSQL: String = {
        let cols = messageColumns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let marks = cols.map { _ in "?" }.joined(separator: ",")
        let updates = cols.dropFirst().map { "\($0)=excluded.\($0)" }.joined(separator: ", ")
        // Stamps `rev` itself, so the row isn't written a second time by the update trigger.
        return "INSERT INTO messages(\(messageColumns), rev) VALUES(\(marks), random()) ON CONFLICT(id) DO UPDATE SET \(updates), rev=random()"
    }()

    // Address lists are stored as "name<US>email<RS>name<US>email" (JSON decoding was the
    // single biggest cost of loading the inbox). Older rows written as JSON are still read.
    static func decodeAddrs(_ s: String) -> [EmailAddress] {
        if s.isEmpty { return [] }
        if s.first == "[" { return (try? JSONDecoder().decode([EmailAddress].self, from: Data(s.utf8))) ?? [] }
        return s.split(separator: "\u{1E}").map { entry in
            let parts = entry.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
            return EmailAddress(name: parts.count > 1 ? String(parts[0]) : "", email: String(parts.last ?? ""))
        }
    }
    static func encodeAddrs(_ a: [EmailAddress]) -> String {
        a.map { $0.name.replacingOccurrences(of: "\u{1E}", with: " ").replacingOccurrences(of: "\u{1F}", with: " ") + "\u{1F}" + $0.email }.joined(separator: "\u{1E}")
    }

    private static var uuidCache: [String: UUID] = [:]
    private static let uuidLock = NSLock()
    static func cachedUUID(_ s: String) -> UUID {
        uuidLock.lock(); defer { uuidLock.unlock() }
        if let u = uuidCache[s] { return u }
        let u = UUID(uuidString: s) ?? UUID()
        uuidCache[s] = u
        return u
    }

    static func message(from r: Row) -> MessageRecord {
        MessageRecord(id: r.string(0), accountId: cachedUUID(r.string(1)), folder: r.string(2), uid: UInt32(r.int(3)),
                      messageId: r.string(4), inReplyTo: r.string(5), references: r.string(6), threadKey: r.string(7),
                      from: EmailAddress(name: r.string(8), email: r.string(9)), to: decodeAddrs(r.string(10)), cc: decodeAddrs(r.string(11)),
                      replyTo: r.string(12), subject: r.string(13), date: Date(timeIntervalSince1970: r.double(14)), snippet: r.string(15),
                      seen: r.bool(16), flagged: r.bool(17), answered: r.bool(18), size: r.int(19),
                      category: MailCategory(rawValue: r.int(20)) ?? .primary, needsReply: r.bool(21),
                      listUnsubscribe: r.string(22), listUnsubscribePost: r.string(23), hasAttachments: r.bool(24),
                      hasBody: r.bool(25), isFromMe: r.bool(26), attachmentNames: r.string(27))
    }

    func upsert(_ m: MessageRecord, bodyText: String? = nil) {
        exec(Database.upsertSQL, [
            m.id, m.accountId.uuidString, m.folder, Int(m.uid), m.messageId, m.inReplyTo, m.references, m.threadKey,
            m.from.name, m.from.email, Database.encodeAddrs(m.to), Database.encodeAddrs(m.cc), m.replyTo, m.subject,
            m.date, m.snippet, m.seen, m.flagged, m.answered, m.size, m.category.rawValue, m.needsReply,
            m.listUnsubscribe, m.listUnsubscribePost, m.hasAttachments, m.hasBody, m.isFromMe, m.attachmentNames])
        let rowid = Database.ftsRowId(m.id)
        exec("DELETE FROM msg_fts WHERE rowid=?", [rowid])
        exec("INSERT INTO msg_fts(rowid, id, subject, sender, body, attachments) VALUES(?,?,?,?,?,?)",
             [rowid, m.id, m.subject, m.from.name + " " + m.from.email, bodyText ?? m.snippet, m.attachmentNames])
    }

    func messages(where clause: String, _ args: [Any?] = [], limit: Int = 2000) -> [MessageRecord] {
        query("SELECT \(Database.selectColumns) FROM messages WHERE \(clause) ORDER BY date DESC LIMIT \(limit)", args, Database.message)
    }

    nonisolated(unsafe) static var rowCacheLimit = 40_000

    /// Same as `messages(where:)`, but rows unchanged since the last call are reused instead of
    /// decoded again: one cheap id+rev scan, then full reads only for new or changed rows.
    func messagesCached(where clause: String, _ args: [Any?] = [], limit: Int = 2000) -> [MessageRecord] {
        let keys = query("SELECT id, rev FROM messages WHERE \(clause) ORDER BY date DESC LIMIT \(limit)", args) { ($0.string(0), $0.int(1)) }
        rowCacheLock.lock(); defer { rowCacheLock.unlock() }
        var stale = keys.filter { rowCache[$0.0]?.rev != $0.1 }.map(\.0)
        // Clearing drops rows this query still needs, so then every requested row is reloaded.
        if rowCache.count + stale.count > Database.rowCacheLimit { rowCache.removeAll(keepingCapacity: true); stale = keys.map(\.0) }
        for chunk in stride(from: 0, to: stale.count, by: 2000).map({ Array(stale[$0..<min($0 + 2000, stale.count)]) }) {
            let json = String(data: (try? JSONSerialization.data(withJSONObject: chunk)) ?? Data(), encoding: .utf8) ?? "[]"
            for (rev, m) in query("SELECT \(Database.selectColumns), rev FROM messages WHERE id IN (SELECT value FROM json_each(?))", [json], {
                ($0.int(28), Database.message(from: $0))
            }) { rowCache[m.id] = (rev, m) }
        }
        return keys.compactMap { rowCache[$0.0]?.rec }
    }

    func message(id: String) -> MessageRecord? { messages(where: "id=?", [id], limit: 1).first }

    func deleteMessage(id: String) {
        exec("DELETE FROM messages WHERE id=?", [id])
        exec("DELETE FROM bodies WHERE id=?", [id])
        exec("DELETE FROM msg_fts WHERE rowid=?", [Database.ftsRowId(id)])
    }

    func raw(for id: String) -> Data? { query("SELECT raw FROM bodies WHERE id=?", [id]) { $0.data(0) }.first ?? nil }
    func setRaw(_ data: Data, for id: String) { exec("INSERT OR REPLACE INTO bodies(id, raw) VALUES(?,?)", [id, data]) }

    struct FolderState { var uidvalidity: UInt32; var lastUID: UInt32; var modseq: UInt64; var exists: Int }

    func folderState(_ account: UUID, _ path: String) -> FolderState? {
        query("SELECT uidvalidity, last_uid, modseq, exists_count FROM folder_state WHERE account=? AND path=?", [account.uuidString, path]) {
            FolderState(uidvalidity: UInt32($0.int(0)), lastUID: UInt32($0.int(1)), modseq: UInt64($0.int(2)), exists: $0.int(3))
        }.first
    }
    func setFolderState(_ account: UUID, _ path: String, uidvalidity: UInt32, lastUID: UInt32, modseq: UInt64 = 0, exists: Int = -1) {
        exec("INSERT OR REPLACE INTO folder_state(account, path, uidvalidity, last_uid, modseq, exists_count) VALUES(?,?,?,?,?,?)",
             [account.uuidString, path, Int(uidvalidity), Int(lastUID), Int64(modseq), exists])
    }

    func saveFolders(_ folders: [MailFolder], account: UUID) {
        transaction {
            exec("DELETE FROM folders WHERE account=?", [account.uuidString])
            for f in folders {
                exec("INSERT INTO folders(account, path, name, role, delim, selectable) VALUES(?,?,?,?,?,?)",
                     [account.uuidString, f.path, f.displayName, f.role.rawValue, f.delimiter, f.selectable])
            }
        }
    }
    func folders(account: UUID) -> [MailFolder] {
        query("SELECT path, name, role, delim, selectable FROM folders WHERE account=? ORDER BY path", [account.uuidString]) {
            MailFolder(accountId: account, path: $0.string(0), displayName: $0.string(1), role: FolderRole(rawValue: $0.string(2)) ?? .other, delimiter: $0.string(3), selectable: $0.bool(4))
        }
    }

    func noteContact(_ a: EmailAddress, date: Date) {
        guard !a.email.isEmpty else { return }
        exec("INSERT INTO contacts(email, name, count, last) VALUES(?,?,1,?) ON CONFLICT(email) DO UPDATE SET count=count+1, last=max(last, excluded.last), name=CASE WHEN excluded.name<>'' THEN excluded.name ELSE name END",
             [a.email.lowercased(), a.name, date])
    }
    func contacts(matching q: String, limit: Int = 8) -> [EmailAddress] {
        query("SELECT name, email FROM contacts WHERE email LIKE ? OR name LIKE ? ORDER BY count DESC, last DESC LIMIT \(limit)", ["%\(q)%", "%\(q)%"]) {
            EmailAddress(name: $0.string(0), email: $0.string(1))
        }
    }
}
