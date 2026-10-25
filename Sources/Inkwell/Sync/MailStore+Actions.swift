import Foundation
import AppKit

extension MailStore {
    // MARK: server ops on message sets

    private func grouped(_ msgs: [MessageRecord]) -> [String: [MessageRecord]] {
        Dictionary(grouping: msgs) { $0.accountId.uuidString + "\u{1}" + $0.folder }
    }

    func setSeen(_ msgs: [MessageRecord], _ seen: Bool, record: Bool = true) async {
        for m in msgs { db.exec("UPDATE messages SET seen=? WHERE id=?", [seen, m.id]) }
        reload()
        for (_, ms) in grouped(msgs) {
            guard let f = ms.first, let conn = connections[f.accountId] else { continue }
            let set = IMAPClient.uidSet(ms.map(\.uid))
            _ = try? await conn.run { c in try c.ensureSelected(f.folder); try c.store(set, flags: "\\Seen", add: seen) }
        }
    }

    func setFlag(_ msgs: [MessageRecord], _ flagged: Bool) async {
        for m in msgs { db.exec("UPDATE messages SET flagged=? WHERE id=?", [flagged, m.id]) }
        reload()
        for (_, ms) in grouped(msgs) {
            guard let f = ms.first, let conn = connections[f.accountId] else { continue }
            let set = IMAPClient.uidSet(ms.map(\.uid))
            _ = try? await conn.run { c in try c.ensureSelected(f.folder); try c.store(set, flags: "\\Flagged", add: flagged) }
        }
    }

    /// Moves messages and offers Undo. Returns false on failure.
    @discardableResult
    func move(_ msgs: [MessageRecord], to dest: String, label: String?) async -> Bool {
        let movable = msgs.filter { $0.folder != dest }
        guard !movable.isEmpty else { return true }
        for m in movable { db.deleteMessage(id: m.id) }
        reload()
        var undoInfo: [(UUID, String, String, [String])] = []  // account, from folder, dest, message-ids
        var ok = true
        for (_, ms) in grouped(movable) {
            guard let f = ms.first, let conn = connections[f.accountId] else { continue }
            let set = IMAPClient.uidSet(ms.map(\.uid))
            do {
                try await conn.run { c in try c.ensureSelected(f.folder); try c.move(set, to: dest) }
                undoInfo.append((f.accountId, f.folder, dest, ms.map(\.messageId).filter { !$0.isEmpty }))
            } catch {
                ok = false
                showToast("Couldn't move: \(error.localizedDescription)", isError: true)
                sync(accountId: f.accountId)
            }
        }
        if let label, ok {
            showToast(label) { [weak self] in
                Task { await self?.undoMove(undoInfo) }
            }
        }
        return ok
    }

    func undoMove(_ info: [(UUID, String, String, [String])]) async {
        for (acct, original, dest, ids) in info {
            guard let conn = connections[acct] else { continue }
            _ = try? await conn.run { c -> Void in
                try c.select(dest)
                var uids: [UInt32] = []
                for id in ids { uids += try c.uidSearch("HEADER Message-ID \(IMAPClient.quote("<\(id)>"))") }
                if !uids.isEmpty { try c.move(IMAPClient.uidSet(uids), to: original) }
            }
            sync(accountId: acct, extraFolder: original)
        }
    }

    // MARK: thread-level actions

    func messages(of threads: [ThreadSummary]) -> [MessageRecord] { threads.flatMap(\.messages) }

    func archive(_ threads: [ThreadSummary]) async {
        for (acct, ts) in Dictionary(grouping: threads, by: \.accountId) {
            guard let a = account(acct) else { continue }
            var dest = a.archiveFolder
            if dest == nil {
                // Create an Archive folder on servers that don't advertise one.
                _ = try? await connections[acct]?.run { c in try c.create("Archive") }
                if let i = settings.accounts.firstIndex(where: { $0.id == acct }) { settings.accounts[i].archiveFolder = "Archive" }
                dest = "Archive"
            }
            let msgs = messages(of: ts).filter { $0.folder != dest && $0.folder != a.sentFolder }
            await move(msgs, to: dest!, label: ts.count == 1 ? "Archived" : "Archived \(ts.count) conversations")
        }
    }

    func trash(_ threads: [ThreadSummary]) async {
        for (acct, ts) in Dictionary(grouping: threads, by: \.accountId) {
            guard let a = account(acct), let dest = a.trashFolder else { continue }
            let msgs = messages(of: ts)
            if msgs.allSatisfy({ $0.folder == dest }) {
                // Already in Trash → delete permanently.
                for (_, ms) in Dictionary(grouping: msgs, by: \.folder) {
                    for m in ms { db.deleteMessage(id: m.id) }
                    _ = try? await connections[acct]?.run { c in try c.select(dest); try c.expunge(IMAPClient.uidSet(ms.map(\.uid))) }
                }
                reload()
                showToast("Deleted permanently", undo: nil)
            } else {
                await move(msgs, to: dest, label: ts.count == 1 ? "Moved to Trash" : "Moved \(ts.count) to Trash")
            }
        }
    }

    func reportSpam(_ threads: [ThreadSummary]) async {
        for (acct, ts) in Dictionary(grouping: threads, by: \.accountId) {
            guard let dest = account(acct)?.spamFolder else { continue }
            await move(messages(of: ts).filter { !$0.isFromMe }, to: dest, label: "Reported as spam")
        }
    }

    func moveThreads(_ threads: [ThreadSummary], to folder: String) async {
        let msgs = messages(of: threads)
        await move(msgs, to: folder, label: "Moved to \(MUTF7.decode(folder))")
    }

    /// Opening a conversation marks it read straight away. Under the "Unread" filter it stays
    /// listed until the user opens something else (see `keptInUnread`).
    func markReadOnOpen(_ messages: [MessageRecord]) async {
        let unread = messages.filter { !$0.seen }
        if !unread.isEmpty { await setSeen(unread, true) }
    }

    func toggleRead(_ threads: [ThreadSummary]) async {
        let anyUnread = threads.contains(where: \.unread)
        await setSeen(messages(of: threads), anyUnread)
    }

    func toggleFlag(_ threads: [ThreadSummary]) async {
        let anyFlagged = threads.contains(where: \.flagged)
        if anyFlagged { await setFlag(messages(of: threads).filter(\.flagged), false) }
        else { await setFlag(threads.map(\.latest), true) }
    }

    func snooze(_ threads: [ThreadSummary], until: Date) {
        for t in threads {
            db.exec("INSERT OR REPLACE INTO snoozes(account, thread_key, until) VALUES(?,?,?)", [t.accountId.uuidString, t.threadKey, until])
        }
        reload()
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; f.doesRelativeDateFormatting = true
        showToast("Snoozed until \(f.string(from: until))") { [weak self] in
            guard let self else { return }
            for t in threads { self.db.exec("DELETE FROM snoozes WHERE account=? AND thread_key=?", [t.accountId.uuidString, t.threadKey]) }
            self.reload()
        }
    }

    func unsnooze(_ threads: [ThreadSummary]) {
        for t in threads { db.exec("DELETE FROM snoozes WHERE account=? AND thread_key=?", [t.accountId.uuidString, t.threadKey]) }
        reload()
    }

    func mute(_ threads: [ThreadSummary]) async {
        for t in threads where !settings.mutedThreads.contains(t.threadKey) { settings.mutedThreads.append(t.threadKey) }
        await setSeen(messages(of: threads), true, record: false)
        await archive(threads)
        showToast("Muted. New replies will skip the inbox.")
    }

    func blockSender(_ email: String) async {
        let e = email.lowercased()
        if !settings.blockedSenders.contains(e) { settings.blockedSenders.append(e) }
        let victims = threads.filter { $0.latest.from.email.lowercased() == e }
        await trash(victims)
        showToast("Blocked \(email)")
    }

    func allowImages(from email: String) {
        let e = email.lowercased()
        if !settings.allowedImageSenders.contains(e) { settings.allowedImageSenders.append(e) }
    }

    // MARK: unsubscribe

    func unsubscribe(_ m: MessageRecord) async {
        let header = m.listUnsubscribe
        let links = MIME.idList(header)
        let https = links.first { $0.lowercased().hasPrefix("https://") }
        let mailto = links.first { $0.lowercased().hasPrefix("mailto:") }
        if let https, m.listUnsubscribePost.lowercased().contains("one-click"), let url = URL(string: https) {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data("List-Unsubscribe=One-Click".utf8)
            if let (_, resp) = try? await URLSession.shared.data(for: req), let h = resp as? HTTPURLResponse, (200..<300).contains(h.statusCode) {
                showToast("Unsubscribed from \(m.from.display)")
                return
            }
        }
        if let mailto, let comps = URLComponents(string: mailto) {
            let to = comps.path
            let subject = comps.queryItems?.first { $0.name.lowercased() == "subject" }?.value ?? "unsubscribe"
            let body = comps.queryItems?.first { $0.name.lowercased() == "body" }?.value ?? "unsubscribe"
            var d = OutgoingDraft(accountId: m.accountId)
            d.fromEmail = account(m.accountId)?.email ?? ""
            d.to = to; d.subject = subject; d.plain = body; d.html = HTMLText.fromPlain(body)
            do { try await deliver(d); showToast("Unsubscribe request sent to \(m.from.display)") }
            catch { showToast("Unsubscribe failed: \(error.localizedDescription)", isError: true) }
            return
        }
        if let https, let url = URL(string: https) { NSWorkspace.shared.open(url); return }
        showToast("No unsubscribe option in this message", isError: true)
    }

    // MARK: search

    nonisolated struct SearchQuery {
        var text = ""
        var from: String?
        var to: String?
        var subject: String?
        var hasAttachment = false
        var unread = false
        var flagged = false
        var account: String?
    }

    nonisolated static func parseSearch(_ q: String) -> SearchQuery {
        var s = SearchQuery()
        var words: [String] = []
        for tok in q.split(separator: " ") {
            let t = String(tok)
            let l = t.lowercased()
            if l == "has:attachment" || l == "has:attachments" { s.hasAttachment = true }
            else if l == "is:unread" { s.unread = true }
            else if l == "is:flagged" || l == "is:starred" { s.flagged = true }
            else if l.hasPrefix("from:") { s.from = String(t.dropFirst(5)) }
            else if l.hasPrefix("to:") { s.to = String(t.dropFirst(3)) }
            else if l.hasPrefix("subject:") { s.subject = String(t.dropFirst(8)) }
            else if l.hasPrefix("account:") { s.account = String(t.dropFirst(8)) }
            else { words.append(t) }
        }
        s.text = words.joined(separator: " ")
        return s
    }

    func localSearch(_ q: String) -> [MessageRecord] {
        let s = MailStore.parseSearch(q)
        var clauses: [String] = ["account IN (\(accountIdsSQL.isEmpty ? "''" : accountIdsSQL))"]
        var args: [Any?] = []
        if !s.text.isEmpty {
            let fts = s.text.split(separator: " ").map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }.joined(separator: " ")
            clauses.append("id IN (SELECT id FROM msg_fts WHERE msg_fts MATCH ?)")
            args.append(fts)
        }
        if let f = s.from { clauses.append("(from_email LIKE ? OR from_name LIKE ?)"); args += ["%\(f)%", "%\(f)%"] }
        if let t = s.to { clauses.append("to_json LIKE ?"); args.append("%\(t)%") }
        if let sub = s.subject { clauses.append("subject LIKE ?"); args.append("%\(sub)%") }
        if s.hasAttachment { clauses.append("has_attach=1") }
        if s.unread { clauses.append("seen=0") }
        if s.flagged { clauses.append("flagged=1") }
        if let a = s.account, let acct = accounts.first(where: { $0.label.lowercased().contains(a.lowercased()) || $0.email.lowercased().contains(a.lowercased()) }) {
            clauses.append("account=?"); args.append(acct.id.uuidString)
        }
        return db.messages(where: clauses.joined(separator: " AND "), args, limit: 200)
    }

    func serverSearch(_ q: String) async -> [MessageRecord] {
        let s = MailStore.parseSearch(q)
        let term = [s.text, s.from, s.subject].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        guard !term.isEmpty else { return [] }
        var out: [MessageRecord] = []
        let db = self.db
        await withTaskGroup(of: [MessageRecord].self) { group in
            for a in accounts {
                guard let conn = connections[a.id] else { continue }
                let acct = account(a.id) ?? a
                group.addTask {
                    (try? await conn.run { c in try SyncEngine.serverSearch(c, account: acct, query: term, db: db) }) ?? []
                }
            }
            for await r in group { out += r }
        }
        return out.sorted { $0.date > $1.date }
    }

    func thread(for m: MessageRecord) -> ThreadSummary {
        let msgs = db.messages(where: "account=? AND thread_key=?", [m.accountId.uuidString, m.threadKey], limit: 200)
        let latest = msgs.first ?? m
        return ThreadSummary(accountId: m.accountId, threadKey: m.threadKey, latest: latest, messages: msgs.isEmpty ? [m] : msgs, count: max(1, msgs.count))
    }
}
