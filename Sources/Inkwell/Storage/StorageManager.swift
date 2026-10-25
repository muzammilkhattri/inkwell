import Foundation

/// Measures what Inkwell keeps on disk and removes downloaded mail to free space.
/// Mail on the server is never touched: removed bodies download again when opened.
enum StorageManager {
    struct AccountUsage: Identifiable, Sendable {
        var id: UUID
        var emails: Int
        var oldest: Date?
        var bytes: Int64
    }

    struct Report: Sendable {
        var total: Int64 = 0
        var bodies: Int64 = 0      // raw messages incl. attachments
        var index: Int64 = 0       // full-text search
        var list: Int64 = 0        // message rows + their indexes
        var other: Int64 = 0       // drafts, image cache, free pages, small tables
        var imageCache: Int64 = 0
        var emails = 0
        var downloaded = 0
        var accounts: [AccountUsage] = []
    }

    struct Options: Equatable, Sendable {
        var olderThanMonths: Int
        var accountIds: [UUID]       // empty = all
        var entireEmails: Bool
        var keepImportant: Bool      // flagged and snoozed
    }

    static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var n: Int64 = 0
        for case let u as URL in e { n += fileSize(u) }
        return n
    }

    /// Approximate bytes a message row takes in `messages`, used where SQLite can't say exactly.
    private static let rowBytesSQL = "(length(id)+length(subject)+length(snippet)+length(to_json)+length(cc_json)+length(refs)+length(from_name)+length(from_email)+length(list_unsub)+length(attach_names)+length(message_id)+length(in_reply_to)+length(thread_key)+80)"

    static func report(db: Database, accountIds: [UUID]) -> Report {
        var r = Report()
        let dbURL = Paths.database
        let dbFile = fileSize(dbURL)
        let wal = fileSize(URL(fileURLWithPath: dbURL.path + "-wal")) + fileSize(URL(fileURLWithPath: dbURL.path + "-shm"))
        r.imageCache = Int64(URLCache.shared.currentDiskUsage)
        let drafts = directorySize(Paths.drafts)

        // Exact per-table sizes when SQLite was built with dbstat; estimates otherwise.
        let pages = db.query("SELECT name, SUM(pgsize) FROM dbstat GROUP BY name") { ($0.string(0), Int64($0.int(1))) }
        if !pages.isEmpty {
            for (name, size) in pages {
                if name == "bodies" || name.hasPrefix("sqlite_autoindex_bodies") { r.bodies += size }
                else if name.hasPrefix("msg_fts") { r.index += size }
                else if name == "messages" || name.hasPrefix("idx_msg") || name.hasPrefix("sqlite_autoindex_messages") { r.list += size }
            }
        } else {
            r.bodies = Int64(db.query("SELECT IFNULL(SUM(length(raw)),0) FROM bodies") { $0.int(0) }.first ?? 0)
            r.list = Int64(db.query("SELECT IFNULL(SUM(\(rowBytesSQL)),0) * 2 FROM messages") { $0.int(0) }.first ?? 0)
            r.index = max(0, dbFile - r.bodies - r.list) * 8 / 10
        }
        r.other = max(0, dbFile - r.bodies - r.index - r.list) + wal + drafts + r.imageCache
        r.total = r.bodies + r.index + r.list + r.other

        r.emails = db.query("SELECT COUNT(*) FROM messages") { $0.int(0) }.first ?? 0
        r.downloaded = db.query("SELECT COUNT(*) FROM bodies") { $0.int(0) }.first ?? 0
        // Each account's share: its bodies plus its rows, with the search index split by message count.
        let indexPerEmail = r.emails > 0 ? Double(r.index) / Double(r.emails) : 0
        let listPerByte: Double = {
            let est = Double(db.query("SELECT IFNULL(SUM(\(rowBytesSQL)),0) FROM messages") { $0.int(0) }.first ?? 0)
            return est > 0 ? Double(r.list) / est : 1
        }()
        for id in accountIds {
            let row = db.query("""
                SELECT COUNT(*), MIN(date), IFNULL(SUM(IFNULL(length(b.raw),0)),0), IFNULL(SUM(\(rowBytesSQL.replacingOccurrences(of: "length(", with: "length(m."))),0)
                FROM messages m LEFT JOIN bodies b ON b.id = m.id WHERE m.account=?
                """, [id.uuidString]) { ($0.int(0), $0.isNull(1) ? nil : Date(timeIntervalSince1970: $0.double(1)), $0.int(2), $0.int(3)) }.first
            guard let row else { continue }
            let bytes = Int64(row.2) + Int64(Double(row.3) * listPerByte) + Int64(Double(row.0) * indexPerEmail)
            r.accounts.append(AccountUsage(id: id, emails: row.0, oldest: row.1, bytes: bytes))
        }
        return r
    }

    private struct Candidate { var id: String; var bodyBytes: Int64; var rowBytes: Int64; var snippet: String }

    private static func candidates(db: Database, _ o: Options, allAccounts: [UUID]) -> [Candidate] {
        let cutoff = Calendar.current.date(byAdding: .month, value: -o.olderThanMonths, to: Date())?.timeIntervalSince1970 ?? 0
        let ids = (o.accountIds.isEmpty ? allAccounts : o.accountIds).map { "'\($0.uuidString)'" }.joined(separator: ",")
        guard !ids.isEmpty else { return [] }
        var clause = "m.date < ? AND m.account IN (\(ids))"
        if o.keepImportant {
            clause += " AND m.flagged=0 AND NOT EXISTS (SELECT 1 FROM snoozes s WHERE s.account=m.account AND s.thread_key=m.thread_key)"
        }
        // Unread mail the unread-backlog sync would just download again, so whole emails only go once read.
        // Bodies-only removal keeps the row (and its unread state), so it's safe for unread mail too.
        if o.entireEmails { clause += " AND m.seen=1" } else { clause += " AND b.id IS NOT NULL" }
        return db.query("""
            SELECT m.id, IFNULL(length(b.raw),0), \(rowBytesSQL.replacingOccurrences(of: "length(", with: "length(m.")), m.snippet
            FROM messages m LEFT JOIN bodies b ON b.id = m.id WHERE \(clause)
            """, [cutoff]) { Candidate(id: $0.string(0), bodyBytes: Int64($0.int(1)), rowBytes: Int64($0.int(2)), snippet: $0.string(3)) }
    }

    /// Emails a clean-up would touch and roughly how many bytes it frees.
    static func estimate(db: Database, _ o: Options, allAccounts: [UUID]) -> (emails: Int, bytes: Int64) {
        let c = candidates(db: db, o, allAccounts: allAccounts)
        // Bodies also carry up to 20 KB of indexed text each; entire emails free their row and index entry too.
        let bytes = c.reduce(Int64(0)) { sum, m in
            sum + m.bodyBytes + (m.bodyBytes > 0 ? min(m.bodyBytes / 3, 20_000) : 0) + (o.entireEmails ? m.rowBytes * 3 : 0)
        }
        return (c.count, bytes)
    }

    /// Removes the selected downloads, then compacts the database so the space really returns
    /// to the disk. Runs off the main thread.
    @discardableResult
    static func cleanUp(db: Database, _ o: Options, allAccounts: [UUID]) -> (emails: Int, freed: Int64) {
        let before = fileSize(Paths.database) + fileSize(URL(fileURLWithPath: Paths.database.path + "-wal"))
        let c = candidates(db: db, o, allAccounts: allAccounts)
        for chunk in stride(from: 0, to: c.count, by: 300).map({ Array(c[$0..<min($0 + 300, c.count)]) }) {
            db.transaction {
                for m in chunk {
                    if o.entireEmails {
                        db.deleteMessage(id: m.id)
                    } else {
                        db.exec("DELETE FROM bodies WHERE id=?", [m.id])
                        db.exec("UPDATE messages SET has_body=0 WHERE id=?", [m.id])
                        // Keep subject/sender searchable; the indexed body shrinks to the preview line.
                        db.exec("UPDATE msg_fts SET body=? WHERE rowid=?", [m.snippet, Database.ftsRowId(m.id)])
                    }
                }
            }
        }
        compact(db: db)
        let after = fileSize(Paths.database) + fileSize(URL(fileURLWithPath: Paths.database.path + "-wal"))
        return (c.count, max(0, before - after))
    }

    static func compact(db: Database) {
        db.exec("INSERT INTO msg_fts(msg_fts) VALUES('optimize')")
        db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        db.exec("VACUUM")
        db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    static func clearImageCache() {
        URLCache.shared.removeAllCachedResponses()
    }
}
