import Foundation

/// Synchronous sync routines; always executed on an AccountConnection's queue.
enum SyncEngine {
    static let headerItems = "UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[HEADER]"
    static let prefetchLimit = 300 * 1024
    nonisolated(unsafe) static var prefetchBatchMax = 150

    static func syncFolders(_ c: IMAPClient, account: inout Account, db: Database) throws -> [MailFolder] {
        let listed = try c.list()
        var folders: [MailFolder] = []
        for item in listed {
            let attrs = item.attrs.map { $0.lowercased() }
            let selectable = !attrs.contains("\\noselect") && !attrs.contains("\\nonexistent")
            var role: FolderRole = .other
            let lowerPath = item.path.lowercased()
            let leaf = MUTF7.decode(item.path).split(separator: Character(item.delimiter.isEmpty ? "/" : item.delimiter)).last.map(String.init) ?? item.path
            let leafLower = leaf.lowercased()
            if lowerPath == "inbox" { role = .inbox }
            else if attrs.contains("\\sent") { role = .sent }
            else if attrs.contains("\\drafts") { role = .drafts }
            else if attrs.contains("\\trash") { role = .trash }
            else if attrs.contains("\\junk") { role = .spam }
            else if attrs.contains("\\all") { role = .all }
            else if attrs.contains("\\archive") { role = .archive }
            else if attrs.contains("\\flagged") { role = .flagged }
            else if ["sent", "sent items", "sent messages", "sent mail"].contains(leafLower) { role = .sent }
            else if ["drafts", "draft"].contains(leafLower) { role = .drafts }
            else if ["trash", "deleted items", "deleted messages", "bin"].contains(leafLower) { role = .trash }
            else if ["junk", "spam", "junk e-mail", "junk email", "bulk mail"].contains(leafLower) { role = .spam }
            else if ["archive", "archives"].contains(leafLower) { role = .archive }
            folders.append(MailFolder(accountId: account.id, path: item.path, displayName: lowerPath == "inbox" ? "Inbox" : leaf,
                                      role: role, delimiter: item.delimiter, selectable: selectable))
        }
        func first(_ r: FolderRole) -> String? { folders.first { $0.role == r && $0.selectable }?.path }
        account.sentFolder = first(.sent)
        account.draftsFolder = first(.drafts)
        account.trashFolder = first(.trash)
        account.spamFolder = first(.spam)
        account.archiveFolder = account.isGmail ? (first(.all) ?? first(.archive)) : (first(.archive) ?? first(.all))
        db.saveFolders(folders, account: account.id)
        return folders
    }

    /// Syncs a folder; returns records that are new since the last sync.
    /// `onNew` fires as soon as new mail is stored with its body, before the slower flag
    /// refresh, so notifications and the code popup don't wait on bookkeeping round trips.
    /// `onHeaders` fires on a first sync once headers are stored, before bodies download.
    @discardableResult
    /// `expectNew`: how many messages IDLE just announced. When it's a handful, SELECT and the
    /// header+body FETCH go out pipelined, so new mail lands in a single round trip.
    static func syncFolder(_ c: IMAPClient, account: Account, path: String, db: Database, initialLimit: Int = 300, expectNew: Int? = nil,
                           onHeaders: (() -> Void)? = nil, onNew: (([MessageRecord]) -> Void)? = nil) throws -> [MessageRecord] {
        let acct = account.id
        var state = db.folderState(acct, path)
        let gmail = c.capabilities.contains("X-GM-EXT-1")
        let items = headerItems + (gmail ? " X-GM-THRID" : "")
        let inlineItems = items + " BODY.PEEK[]<0.\(prefetchLimit)>"
        let info: SelectInfo
        var pipelined: [FetchResult]?
        let categorize = gmail && path == "INBOX"
        var gmCats: [[UInt32]]?
        if let s = state, s.exists >= 0, let n = expectNew, (1...25).contains(n) {
            c.forgetSelection()
            // Gmail's tab for the new mail rides along in the same round trip.
            let range = "\(s.lastUID + 1):*"
            let r = try c.pipeline([c.selectCommand(path), IMAPClient.fetchCommand(range, items: inlineItems)]
                                   + (categorize ? gmailCategoryCommands(uidRange: range) : []))
            info = IMAPClient.parseSelect(r[0])
            c.didSelect(path, info)
            if info.uidValidity == s.uidvalidity {
                pipelined = IMAPClient.parseFetch(r[1]).filter { $0.uid > s.lastUID }
                if categorize { gmCats = r.dropFirst(2).map { IMAPClient.parseSearch($0).filter { $0 > s.lastUID } } }
            }
        } else {
            info = try c.takeFreshSelect(path) ?? c.select(path, readOnly: false)
        }
        if let s = state, s.uidvalidity != info.uidValidity {
            for m in db.messages(where: "account=? AND folder=?", [acct.uuidString, path], limit: 100000) { db.deleteMessage(id: m.id) }
            state = nil
        }
        // CONDSTORE: if neither the mod-sequence nor the message count moved, nothing changed.
        if let st = state, info.highestModSeq > 0, st.modseq == info.highestModSeq, st.exists == info.exists {
            return []
        }

        // 1. New mail first: it's what the user is waiting for.
        var fetched: [FetchResult] = []
        // A handful of new messages (the IDLE case): pull headers and bodies in one round trip.
        // The body is capped at the prefetch limit; bigger messages keep only their headers.
        var inlineBodies = false
        if info.exists == 0 {
            fetched = []
        } else if let p = pipelined {
            fetched = p; inlineBodies = true
        } else if let s = state {
            let growth = info.exists - max(s.exists, 0)
            inlineBodies = s.exists >= 0 && growth > 0 && growth <= 25
            fetched = try c.fetch("\(s.lastUID + 1):*", items: inlineBodies ? inlineItems : items).filter { $0.uid > s.lastUID }
        } else {
            let from = max(1, info.exists - initialLimit + 1)
            fetched = try c.fetch("\(from):*", items: items, byUID: false)
        }

        var newRecords: [MessageRecord] = []
        var enriched: [String: MessageRecord] = [:]
        db.transaction {
            for f in fetched {
                guard let h = f.header else { continue }
                let rec = record(fetch: f, header: h, account: account, folder: path, uidValidity: info.uidValidity)
                db.upsert(rec)
                newRecords.append(rec)
                if inlineBodies, rec.size < prefetchLimit, let raw = f.body, raw.count >= rec.size {
                    enriched[rec.id] = applyBody(raw, to: rec, account: account, db: db)
                }
            }
        }
        var gmByUID: [UInt32: MailCategory] = [:]
        if categorize, let lo = fetched.map(\.uid).min() {
            if gmCats == nil { gmCats = try c.pipeline(gmailCategoryCommands(uidRange: "\(lo):*")).map(IMAPClient.parseSearch) }
            gmByUID = applyGmailCategories(gmCats ?? [], account: account, path: path, uidValidity: info.uidValidity, db: db)
        }
        let maxUID = max(fetched.map(\.uid).max() ?? 0, state?.lastUID ?? 0)
        // New mail is stored: record it now (old mod-sequence, unknown count) so a failure in
        // the flag refresh below re-runs only that, never re-announces these messages.
        db.setFolderState(acct, path, uidvalidity: info.uidValidity, lastUID: maxUID, modseq: state?.modseq ?? 0, exists: -1)
        if !newRecords.isEmpty, state == nil { onHeaders?() }
        let rest = newRecords.filter { enriched[$0.id] == nil }
        if !rest.isEmpty { enriched.merge(try prefetchBodies(c, rest, account: account, db: db)) { a, _ in a } }
        let result = newRecords.map { m -> MessageRecord in
            var r = enriched[m.id] ?? m
            if let cat = gmByUID[r.uid] { r.category = cat }
            return r
        }
        if !result.isEmpty { onNew?(result) }

        // 2. Flag refresh + deletion detection for the window we track locally.
        let local = db.query("SELECT id, uid FROM messages WHERE account=? AND folder=? ORDER BY uid DESC LIMIT 600", [acct.uuidString, path]) { ($0.string(0), UInt32($0.int(1))) }
        if let minUID = local.map(\.1).min(), info.exists > 0 {
            if let st = state, st.modseq > 0, info.highestModSeq > 0 {
                // Only messages whose flags changed since last sync, plus a UID list for expunges;
                // both share one round trip. The count tells whether anything was deleted at all:
                // if old count + arrivals = new count, skip the UID list (thousands of UIDs).
                let anyExpunged = st.exists < 0 || st.exists + fetched.count != info.exists
                let r = try c.pipeline([IMAPClient.fetchCommand("\(minUID):*", items: "UID FLAGS", changedSince: st.modseq)]
                                       + (anyExpunged ? ["UID SEARCH UID \(minUID):*"] : []))
                let changed = IMAPClient.parseFetch(r[0])
                let alive = anyExpunged ? Set(IMAPClient.parseSearch(r[1])) : nil
                let localIds = Dictionary(local.map { ($0.1, $0.0) }, uniquingKeysWith: { a, _ in a })
                db.transaction {
                    if let alive { for (id, uid) in local where !alive.contains(uid) { db.deleteMessage(id: id) } }
                    for f in changed {
                        guard let id = localIds[f.uid] else { continue }
                        db.exec("UPDATE messages SET seen=?, flagged=?, answered=? WHERE id=?",
                                [f.flags.contains("\\Seen"), f.flags.contains("\\Flagged"), f.flags.contains("\\Answered"), id])
                    }
                }
            } else {
                let flags = try c.fetch("\(minUID):*", items: "UID FLAGS")
                let byUID = Dictionary(flags.map { ($0.uid, $0.flags) }, uniquingKeysWith: { a, _ in a })
                db.transaction {
                    for (id, uid) in local {
                        guard let f = byUID[uid] else { db.deleteMessage(id: id); continue }
                        db.exec("UPDATE messages SET seen=?, flagged=?, answered=? WHERE id=?",
                                [f.contains("\\Seen"), f.contains("\\Flagged"), f.contains("\\Answered"), id])
                    }
                }
            }
        } else if info.exists == 0 {
            for (id, _) in local { db.deleteMessage(id: id) }
        }
        db.setFolderState(acct, path, uidvalidity: info.uidValidity, lastUID: maxUID, modseq: info.highestModSeq, exists: info.exists)
        return result
    }

    // MARK: Gmail tabs

    /// Gmail's inbox tabs, in our three: Social and Forums sit with Updates.
    static let gmailGroups: [(MailCategory, String)] = [
        (.primary, "category:primary"),
        (.updates, "category:updates OR category:social OR category:forums"),
        (.promos, "category:promotions"),
    ]

    static func gmailCategoryCommands(uidRange: String?) -> [String] {
        gmailGroups.map { "UID SEARCH " + (uidRange.map { "UID \($0) " } ?? "") + "X-GM-RAW " + IMAPClient.quote($0.1) }
    }

    /// Stores Gmail's tab for each UID found by `gmailCategoryCommands` (results in `gmailGroups` order).
    @discardableResult
    static func applyGmailCategories(_ results: [[UInt32]], account: Account, path: String, uidValidity: UInt32, db: Database) -> [UInt32: MailCategory] {
        var byUID: [UInt32: MailCategory] = [:]
        for (i, uids) in results.enumerated() where i < gmailGroups.count {
            for u in uids where byUID[u] == nil { byUID[u] = gmailGroups[i].0 }
        }
        guard !byUID.isEmpty else { return [:] }
        let prefix = "\(account.id.uuidString)|\(path)|\(uidValidity)|"
        db.transaction {
            for (u, cat) in byUID { db.exec("UPDATE messages SET gm_cat=? WHERE id=?", [cat.rawValue, prefix + "\(u)"]) }
        }
        return byUID
    }

    /// Re-reads Gmail's tab for the whole inbox (mail moved between tabs, mail synced before this
    /// existed). Three searches in one round trip. No-op on other servers.
    static func syncGmailCategories(_ c: IMAPClient, account: Account, db: Database) throws {
        guard c.capabilities.contains("X-GM-EXT-1") else { return }
        try c.ensureReadable("INBOX")
        guard let info = c.selectInfo, info.exists > 0 else { return }
        let results = try c.pipeline(gmailCategoryCommands(uidRange: nil)).map(IMAPClient.parseSearch)
        // No categories at all means Gmail isn't sorting this mailbox; keep our own classification.
        guard results.contains(where: { !$0.isEmpty }) else { return }
        let found = applyGmailCategories(results, account: account, path: "INBOX", uidValidity: info.uidValidity, db: db)
        // Local inbox mail Gmail no longer files under a tab falls back to our own classification.
        let prefix = "\(account.id.uuidString)|INBOX|\(info.uidValidity)|"
        let stale = db.query("SELECT id, uid FROM messages WHERE account=? AND folder='INBOX' AND gm_cat IS NOT NULL", [account.id.uuidString]) {
            ($0.string(0), UInt32($0.int(1)))
        }.filter { $0.0.hasPrefix(prefix) && found[$0.1] == nil }
        if !stale.isEmpty { db.transaction { for (id, _) in stale { db.exec("UPDATE messages SET gm_cat=NULL WHERE id=?", [id]) } } }
    }

    /// Prefetch bodies for small messages so they open instantly and are searchable offline.
    /// Batch by ~3 MB per FETCH so a fresh account needs a handful of round trips, not dozens.
    /// Expects the records' folder to be selected.
    private static func prefetchBodies(_ c: IMAPClient, _ records: [MessageRecord], account: Account, db: Database) throws -> [String: MessageRecord] {
        let small = records.filter { $0.size < prefetchLimit }
        var chunks: [[UInt32]] = [[]]
        var budget = 0
        for r in small {
            if budget + r.size > 3_000_000 || chunks[chunks.count - 1].count >= prefetchBatchMax { chunks.append([]); budget = 0 }
            chunks[chunks.count - 1].append(r.uid); budget += r.size
        }
        let byUID = Dictionary(records.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        var enriched: [String: MessageRecord] = [:]
        // All chunks go out at once; each is parsed and stored as its response completes.
        let cmds = chunks.filter { !$0.isEmpty }.map { IMAPClient.fetchCommand(IMAPClient.uidSet($0), items: "UID BODY.PEEK[]") }
        try c.pipeline(cmds) { _, lines in
            let bodies = IMAPClient.parseFetch(lines)
            db.transaction {
                for b in bodies {
                    guard let raw = b.body, let rec = byUID[b.uid] else { continue }
                    let updated = applyBody(raw, to: rec, account: account, db: db)
                    enriched[rec.id] = updated
                }
            }
        }
        return enriched
    }

    /// Regular sync only keeps the newest few hundred messages of a folder. This pulls in every
    /// unread message the server has beyond that window (newest first, `limit` per call, so a
    /// huge backlog fills in over a few syncs) and fixes the read state of older local copies,
    /// whose flags the windowed refresh in `syncFolder` never looks at.
    /// Returns the number of messages added.
    @discardableResult
    static func syncUnread(_ c: IMAPClient, account: Account, path: String, db: Database, limit: Int = 500, selected: SelectInfo? = nil) throws -> Int {
        let info = try selected ?? c.select(path, readOnly: false)
        let acct = account.id.uuidString
        guard info.exists > 0 else { return 0 }
        let unseen = Set(try c.uidSearch("UNSEEN"))
        let prefix = "\(acct)|\(path)|\(info.uidValidity)|"
        let local = db.query("SELECT id, uid, seen FROM messages WHERE account=? AND folder=?", [acct, path]) {
            (id: $0.string(0), uid: UInt32($0.int(1)), seen: $0.bool(2))
        }.filter { $0.id.hasPrefix(prefix) }

        let staleUnread = local.filter { !$0.seen && !unseen.contains($0.uid) }
        let alive = staleUnread.isEmpty ? [] : Set(try c.uidSearch("UID \(IMAPClient.uidSet(staleUnread.map(\.uid)))"))
        db.transaction {
            for m in staleUnread {
                if alive.contains(m.uid) { db.exec("UPDATE messages SET seen=1 WHERE id=?", [m.id]) } else { db.deleteMessage(id: m.id) }
            }
            for m in local where m.seen && unseen.contains(m.uid) { db.exec("UPDATE messages SET seen=0 WHERE id=?", [m.id]) }
        }

        let have = Set(local.map(\.uid))
        let missing = Array(unseen.subtracting(have).sorted(by: >).prefix(limit))
        guard !missing.isEmpty else { return 0 }
        let gmail = c.capabilities.contains("X-GM-EXT-1")
        let fetched = try c.fetch(IMAPClient.uidSet(missing), items: headerItems + (gmail ? " X-GM-THRID" : ""))
        var added: [MessageRecord] = []
        db.transaction {
            for f in fetched {
                guard let h = f.header else { continue }
                let rec = record(fetch: f, header: h, account: account, folder: path, uidValidity: info.uidValidity)
                db.upsert(rec)
                added.append(rec)
            }
        }
        _ = try prefetchBodies(c, added, account: account, db: db)
        return added.count
    }

    static func threadKey(messageId: String, inReplyTo: String, references: [String], subject: String, gmThread: String?) -> String {
        if let g = gmThread, !g.isEmpty { return "gm:" + g }
        if let r = references.first { return r }
        if !inReplyTo.isEmpty { return inReplyTo }
        if !messageId.isEmpty { return messageId }
        return "subj:" + normalizeSubject(subject)
    }

    static func normalizeSubject(_ s: String) -> String {
        s.replacingOccurrences(of: "^((re|fwd?|aw|sv|antw)(\\[\\d+\\])?:\\s*)+", with: "", options: [.regularExpression, .caseInsensitive]).lowercased()
    }

    static func record(fetch f: FetchResult, header: Data, account: Account, folder: String, uidValidity: UInt32) -> MessageRecord {
        let headers = MIME.parseHeaders(header)
        func hv(_ n: String) -> String { headers.first { $0.0.caseInsensitiveCompare(n) == .orderedSame }?.1 ?? "" }
        let from = MIME.parseAddressList(hv("From")).first ?? EmailAddress(name: "", email: "")
        let subject = MIME.decodeHeader(hv("Subject"))
        let mid = MIME.cleanId(hv("Message-ID"))
        let irt = MIME.cleanId(MIME.idList(hv("In-Reply-To")).first ?? hv("In-Reply-To"))
        let refs = MIME.idList(hv("References"))
        let isFromMe = account.allAddresses.contains(from.email.lowercased())
        let category = Classifier.category(from: from, subject: subject, text: "", headers: headers)
        let ctype = hv("Content-Type").lowercased()
        return MessageRecord(
            id: "\(account.id.uuidString)|\(folder)|\(uidValidity)|\(f.uid)", accountId: account.id, folder: folder, uid: f.uid,
            messageId: mid, inReplyTo: irt, references: refs.joined(separator: " "),
            threadKey: threadKey(messageId: mid, inReplyTo: irt, references: refs, subject: subject, gmThread: f.gmThreadId),
            from: from, to: MIME.parseAddressList(hv("To")), cc: MIME.parseAddressList(hv("Cc")), replyTo: hv("Reply-To"),
            subject: subject, date: MIME.parseDate(hv("Date")) ?? f.internalDate ?? Date(), snippet: "",
            seen: f.flags.contains("\\Seen"), flagged: f.flags.contains("\\Flagged"), answered: f.flags.contains("\\Answered"),
            size: f.size, category: category, needsReply: false,
            listUnsubscribe: hv("List-Unsubscribe"), listUnsubscribePost: hv("List-Unsubscribe-Post"),
            hasAttachments: ctype.contains("multipart/mixed"), hasBody: false, isFromMe: isFromMe, attachmentNames: "")
    }

    @discardableResult
    static func applyBody(_ raw: Data, to rec: MessageRecord, account: Account, db: Database) -> MessageRecord {
        let parsed = MIME.parse(raw)
        var r = rec
        let plain = parsed.plainText
        r.snippet = HTMLText.snippet(parsed)
        let atts = parsed.visibleAttachments
        r.hasAttachments = !atts.isEmpty
        r.attachmentNames = atts.map(\.filename).joined(separator: ", ")
        r.category = Classifier.category(from: r.from, subject: r.subject, text: plain, headers: parsed.headers)
        r.needsReply = Classifier.needsReply(from: r.from, isFromMe: r.isFromMe, category: r.category, text: plain, headers: parsed.headers)
        r.hasBody = true
        // Only the body-derived fields: the row may have been read, flagged, moved or deleted
        // while this body was downloading, and those newer changes must stand.
        let updated = db.execChanges("UPDATE messages SET snippet=?, has_attach=?, attach_names=?, category=?, needs_reply=?, has_body=1 WHERE id=?",
                                     [r.snippet, r.hasAttachments, r.attachmentNames, r.category.rawValue, r.needsReply, r.id])
        guard updated > 0 else { return r }  // gone locally: don't bring it back
        db.setRaw(raw, for: r.id)
        db.exec("UPDATE msg_fts SET body=?, attachments=? WHERE rowid=?", [String(plain.prefix(20000)), r.attachmentNames, Database.ftsRowId(r.id)])
        if !r.isFromMe && r.category == .primary { db.noteContact(r.from, date: r.date) }
        if r.isFromMe { for a in r.to + r.cc { db.noteContact(a, date: r.date) } }
        return r
    }

    /// One-time pass after classifier/snippet improvements: recompute preview text, tab and
    /// "needs reply" for every message whose body is stored locally. Runs off the main thread.
    static func reprocessStoredBodies(db: Database) -> Int {
        let ids = db.query("SELECT b.id, m.from_me FROM bodies b JOIN messages m ON m.id = b.id") { ($0.string(0), $0.bool(1)) }
        var n = 0
        for chunk in stride(from: 0, to: ids.count, by: 200).map({ Array(ids[$0..<min($0 + 200, ids.count)]) }) {
            db.transaction {
                for (id, fromMe) in chunk {
                    guard let raw = db.raw(for: id) else { continue }
                    let p = MIME.parse(raw)
                    let plain = p.plainText
                    let cat = Classifier.category(from: p.from, subject: p.subject, text: plain, headers: p.headers)
                    let needs = Classifier.needsReply(from: p.from, isFromMe: fromMe, category: cat, text: plain, headers: p.headers)
                    db.exec("UPDATE messages SET snippet=?, category=?, needs_reply=? WHERE id=?", [HTMLText.snippet(p), cat.rawValue, needs, id])
                    n += 1
                }
            }
        }
        return n
    }

    static func fetchBody(_ c: IMAPClient, rec: MessageRecord, account: Account, db: Database) throws -> Data? {
        try c.ensureReadable(rec.folder)
        guard let b = try c.fetch("\(rec.uid)", items: "UID BODY.PEEK[]").first?.body else { return nil }
        applyBody(b, to: rec, account: account, db: db)
        return b
    }

    /// Server-side search across Inbox, Sent and the archive folder.
    static func serverSearch(_ c: IMAPClient, account: Account, query: String, db: Database) throws -> [MessageRecord] {
        var folders = ["INBOX"]
        if let s = account.sentFolder { folders.append(s) }
        if let a = account.archiveFolder, !folders.contains(a) { folders.append(a) }
        var results: [MessageRecord] = []
        let q = IMAPClient.quote(query)
        for f in folders {
            let info = try c.select(f, readOnly: true)
            var uids: [UInt32]
            if c.capabilities.contains("X-GM-EXT-1") {
                uids = try c.uidSearch("X-GM-RAW \(q)")
            } else {
                uids = try c.uidSearch("OR OR FROM \(q) SUBJECT \(q) BODY \(q)")
            }
            uids = Array(uids.sorted(by: >).prefix(50))
            guard !uids.isEmpty else { continue }
            let gmail = c.capabilities.contains("X-GM-EXT-1")
            let fetched = try c.fetch(IMAPClient.uidSet(uids), items: headerItems + (gmail ? " X-GM-THRID" : ""))
            for fr in fetched {
                guard let h = fr.header else { continue }
                let id = "\(account.id.uuidString)|\(f)|\(info.uidValidity)|\(fr.uid)"
                if let existing = db.message(id: id) { results.append(existing); continue }
                let rec = record(fetch: fr, header: h, account: account, folder: f, uidValidity: info.uidValidity)
                db.upsert(rec)
                results.append(rec)
            }
        }
        return results
    }
}
