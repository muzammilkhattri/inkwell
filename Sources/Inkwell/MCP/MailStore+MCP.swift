import Foundation
import AppKit

struct AIActivity: Identifiable {
    var id: Int
    var date: Date
    var app: String
    var action: String
    var detail: String
    var undone: Bool
}

extension MailStore {
    /// Executes actions queued by `Inkwell --mcp`.
    func processPendingActions() {
        guard settings.mcpEnabled else { return }
        let rows = db.query("SELECT id, app, json FROM pending_actions ORDER BY id LIMIT 20") { ($0.int(0), $0.string(1), $0.data(2)) }
        for (id, app, json) in rows {
            db.exec("DELETE FROM pending_actions WHERE id=?", [id])
            guard let json, let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
                  let action = obj["action"] as? String else { continue }
            let args = obj["args"] as? [String: Any] ?? [:]
            Task { await self.execute(action: action, args: args, app: app) }
        }
    }

    private func threadsFor(_ ids: [String]) -> [ThreadSummary] {
        ids.compactMap { tid in
            guard let bar = tid.firstIndex(of: "|"), let acct = UUID(uuidString: String(tid[..<bar])) else { return nil }
            let key = String(tid[tid.index(after: bar)...])
            let msgs = db.messages(where: "account=? AND thread_key=?", [acct.uuidString, key], limit: 200)
            guard let latest = msgs.first else { return nil }
            return ThreadSummary(accountId: acct, threadKey: key, latest: latest, messages: msgs, count: msgs.count)
        }
    }

    private func confirm(_ title: String, _ info: String, ok: String = "Allow") -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.addButton(withTitle: ok)
        a.addButton(withTitle: "Don't Allow")
        return a.runModal() == .alertFirstButtonReturn
    }

    func logActivity(app: String, action: String, detail: String, undo: [String: Any]? = nil) {
        let data = undo.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        db.exec("INSERT INTO ai_activity(ts, app, action, detail, undo) VALUES(?,?,?,?,?)", [Date(), app, action, detail, data])
    }

    func aiActivity(limit: Int = 100) -> [AIActivity] {
        db.query("SELECT id, ts, app, action, detail, undone FROM ai_activity ORDER BY id DESC LIMIT \(limit)") {
            AIActivity(id: $0.int(0), date: Date(timeIntervalSince1970: $0.double(1)), app: $0.string(2), action: $0.string(3), detail: $0.string(4), undone: $0.bool(5))
        }
    }

    func undoActivity(_ id: Int) async {
        guard let data = db.query("SELECT undo FROM ai_activity WHERE id=?", [id], { $0.data(0) }).first ?? nil,
              let undo = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let kind = undo["kind"] as? String else { return }
        db.exec("UPDATE ai_activity SET undone=1 WHERE id=?", [id])
        let ids = undo["thread_ids"] as? [String] ?? []
        switch kind {
        case "unarchive":
            // Pull messages back to Inbox from wherever they were moved.
            for t in threadsFor(ids) {
                let msgs = t.messages.filter { $0.folder != "INBOX" }
                await move(msgs, to: "INBOX", label: nil)
            }
        case "mark_read":
            await setSeen(messages(of: threadsFor(ids)), undo["read"] as? Bool ?? false)
        case "flag":
            await setFlag(messages(of: threadsFor(ids)), undo["flagged"] as? Bool ?? false)
        case "unsnooze":
            unsnooze(threadsFor(ids))
        case "unmute":
            let keys = Set(threadsFor(ids).map(\.threadKey))
            settings.mutedThreads.removeAll { keys.contains($0) }
        default: break
        }
        reload()
    }

    private func execute(action: String, args: [String: Any], app: String) async {
        let ids = args["thread_ids"] as? [String] ?? []
        let threads = threadsFor(ids)
        if threads.count > 25 && !confirm("\(app) wants to change \(threads.count) conversations", "Action: \(action). Allow it?") { return }
        let subj = threads.prefix(3).map { "“\($0.latest.subject)”" }.joined(separator: ", ") + (threads.count > 3 ? " +\(threads.count - 3)" : "")
        switch action {
        case "open_draft":
            if let idS = args["draft_id"] as? String, let d = localDrafts().first(where: { $0.id.uuidString == idS }) {
                drafts[d.id] = d
                logActivity(app: app, action: "Drafted", detail: d.subject)
            }
        case "send_draft":
            guard let idS = args["draft_id"] as? String, let d = localDrafts().first(where: { $0.id.uuidString == idS }) else { return }
            let trusted = trustedRecipients[app] ?? []
            let recipients = Set((MIME.parseAddressList(d.to) + MIME.parseAddressList(d.cc) + MIME.parseAddressList(d.bcc)).map { $0.email.lowercased() })
            if !recipients.isEmpty && recipients.isSubset(of: trusted) {
                queueSend(d)
                logActivity(app: app, action: "Sent", detail: "\(d.subject) → \(d.to)")
            } else {
                NSApp.activate(ignoringOtherApps: true)
                pendingApproval = PendingSendApproval(draft: d, app: app, actionId: 0)
            }
        case "archive":
            await archive(threads)
            logActivity(app: app, action: "Archived", detail: subj, undo: ["kind": "unarchive", "thread_ids": ids])
        case "mark_read":
            let read = args["read"] as? Bool ?? true
            await setSeen(messages(of: threads), read)
            logActivity(app: app, action: read ? "Marked read" : "Marked unread", detail: subj, undo: ["kind": "mark_read", "thread_ids": ids, "read": !read])
        case "flag":
            let f = args["flagged"] as? Bool ?? true
            await setFlag(threads.map(\.latest), f)
            logActivity(app: app, action: f ? "Flagged" : "Unflagged", detail: subj, undo: ["kind": "flag", "thread_ids": ids, "flagged": !f])
        case "move":
            let folder = args["folder"] as? String ?? "INBOX"
            await move(messages(of: threads), to: folder, label: nil)
            logActivity(app: app, action: "Moved to \(MUTF7.decode(folder))", detail: subj, undo: ["kind": "unarchive", "thread_ids": ids])
        case "snooze":
            if let u = args["until"] as? String, let d = ISO8601DateFormatter().date(from: u) ?? { let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]; return f.date(from: u) }() {
                snooze(threads, until: d)
                logActivity(app: app, action: "Snoozed", detail: subj, undo: ["kind": "unsnooze", "thread_ids": ids])
            }
        case "mute":
            await mute(threads)
            logActivity(app: app, action: "Muted", detail: subj, undo: ["kind": "unmute", "thread_ids": ids])
        case "remind":
            if let tid = args["thread_id"] as? String, let t = threadsFor([tid]).first {
                let days = Double(args["days"] as? Int ?? 3)
                db.exec("INSERT OR REPLACE INTO reminders(account, thread_key, until, sent_date, subject) VALUES(?,?,?,?,?)",
                        [t.accountId.uuidString, t.threadKey, Date().addingTimeInterval(days * 86400), t.latest.date, t.latest.subject])
                logActivity(app: app, action: "Reminder set", detail: t.latest.subject)
            }
        case "create_folder":
            if let a = (args["account"] as? String).flatMap(UUID.init(uuidString:)), let n = args["name"] as? String, let conn = connections[a] {
                _ = try? await conn.run { c in try c.create(MUTF7.encode(n)) }
                lastFolderListReset(a)
                logActivity(app: app, action: "Created folder", detail: n)
            }
        case "create_rule":
            var r = Rule()
            r.name = args["name"] as? String ?? "Rule from \(app)"
            r.field = Rule.Field(rawValue: args["field"] as? String ?? "") ?? .from
            r.value = args["value"] as? String ?? ""
            r.action = Rule.Action(rawValue: args["action"] as? String ?? "") ?? .archive
            if r.action == .trash { r.action = .archive }
            r.targetFolder = args["folder"] as? String ?? ""
            if confirm("\(app) wants to add a rule", "\(r.field.label) “\(r.value)” → \(r.action.label)\(r.targetFolder.isEmpty ? "" : " “\(r.targetFolder)”")") {
                settings.rules.append(r)
                logActivity(app: app, action: "Created rule", detail: r.name)
            }
        case "unsubscribe":
            if let mid = args["message_id"] as? String, let m = db.message(id: mid),
               confirm("\(app) wants to unsubscribe you", "From \(m.from.display) <\(m.from.email)>") {
                await unsubscribe(m)
                logActivity(app: app, action: "Unsubscribed", detail: m.from.email)
            }
        case "block":
            if let e = args["email"] as? String, confirm("\(app) wants to block a sender", e) {
                await blockSender(e)
                logActivity(app: app, action: "Blocked", detail: e)
            }
        default: break
        }
    }

    func approvePendingSend(trustRecipients: Bool, edit: Bool) {
        guard let p = pendingApproval else { return }
        pendingApproval = nil
        if edit {
            drafts[p.draft.id] = p.draft
            openCompose?(p.draft.id)
            return
        }
        if trustRecipients {
            let r = (MIME.parseAddressList(p.draft.to) + MIME.parseAddressList(p.draft.cc) + MIME.parseAddressList(p.draft.bcc)).map { $0.email.lowercased() }
            trustedRecipients[p.app, default: []].formUnion(r)
        }
        queueSend(p.draft)
        logActivity(app: p.app, action: "Sent", detail: "\(p.draft.subject) → \(p.draft.to)")
    }

    func rejectPendingSend() {
        if let p = pendingApproval { logActivity(app: p.app, action: "Send declined", detail: p.draft.subject) }
        pendingApproval = nil
    }
}
