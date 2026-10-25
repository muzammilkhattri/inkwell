import Foundation

/// Stdio MCP server: `Inkwell --mcp`. Reads straight from the local mail database and queues
/// changes for the running app (which asks before sending, and logs everything in Settings → AI).
final class MCPServer {
    private let db = Database(path: Paths.database.path)
    private var clientName = "AI app"
    private let out = FileHandle.standardOutput

    static func run() -> Never {
        let s = MCPServer()
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            s.handle(msg)
        }
        exit(0)
    }

    private var settings: AppSettings { SettingsStore.load() }

    private func allowedAccounts() -> [Account] {
        let s = settings
        return s.accounts.filter { s.mcpAllows($0) }
    }

    private func send(_ obj: [String: Any]) {
        guard var d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        d.append(10)
        out.write(d)
    }

    private func handle(_ msg: [String: Any]) {
        let id = msg["id"]
        let method = msg["method"] as? String ?? ""
        let params = msg["params"] as? [String: Any] ?? [:]
        func reply(_ result: Any) { if let id { send(["jsonrpc": "2.0", "id": id, "result": result]) } }
        func fail(_ code: Int, _ message: String) { if let id { send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]) } }

        switch method {
        case "initialize":
            if let ci = params["clientInfo"] as? [String: Any], let n = ci["name"] as? String { clientName = n }
            reply(["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                   "capabilities": ["tools": [:]],
                   "serverInfo": ["name": "inkwell", "version": "1.0.0"],
                   "instructions": "Local email for the user's Mac. Reading/searching works any time; changes are applied when Inkwell is open. Sending always asks the user first."])
        case "notifications/initialized", "notifications/cancelled": break
        case "ping": reply([:])
        case "tools/list": reply(["tools": MCPServer.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            guard settings.mcpEnabled else {
                reply(["content": [["type": "text", "text": "Inkwell MCP is turned off. Ask the user to enable it in Inkwell → Settings → AI."]], "isError": true]); return
            }
            do {
                let result = try call(name, args)
                let text: String
                if let s = result as? String { text = s }
                else { text = String(decoding: (try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])) ?? Data(), as: UTF8.self) }
                reply(["content": [["type": "text", "text": text]]])
            } catch {
                reply(["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
            }
        default:
            fail(-32601, "Method not found: \(method)")
        }
    }

    // MARK: tool definitions

    private static func tool(_ name: String, _ desc: String, _ props: [String: [String: Any]], required: [String] = []) -> [String: Any] {
        ["name": name, "description": desc, "inputSchema": ["type": "object", "properties": props, "required": required]]
    }
    private static let str: [String: Any] = ["type": "string"]
    private static let int: [String: Any] = ["type": "integer"]
    private static let bool: [String: Any] = ["type": "boolean"]
    private static let ids: [String: Any] = ["type": "array", "items": ["type": "string"], "description": "thread_id values from list_threads/search_messages"]

    static let tools: [[String: Any]] = [
        tool("list_accounts", "List the mail accounts the user shared with AI apps.", [:]),
        tool("list_folders", "List folders for an account.", ["account": str], required: ["account"]),
        tool("list_threads", "List conversations in a mailbox. mailbox: inbox | to_reply | flagged | snoozed | primary | updates | promos | <folder path>.",
             ["mailbox": str, "account": str, "unread_only": bool, "limit": int]),
        tool("search_messages", "Search mail (supports from:, to:, subject:, has:attachment, is:unread).", ["query": str, "limit": int], required: ["query"]),
        tool("get_thread", "Read a full conversation.", ["thread_id": str], required: ["thread_id"]),
        tool("get_message", "Read one message by message_id.", ["message_id": str], required: ["message_id"]),
        tool("find_attachments", "Find attachments by file name or sender.", ["query": str, "limit": int], required: ["query"]),
        tool("find_contacts", "Find people the user emails with.", ["query": str], required: ["query"]),
        tool("list_drafts", "List drafts waiting in Inkwell.", [:]),
        tool("create_draft", "Create a draft. It opens in Inkwell tagged with your name; nothing is sent.",
             ["to": str, "cc": str, "subject": str, "body": str, "reply_to_message_id": str, "account": str], required: ["body"]),
        tool("update_draft", "Change an existing draft.", ["draft_id": str, "to": str, "cc": str, "subject": str, "body": str], required: ["draft_id"]),
        tool("send_draft", "Ask the user to send a draft. Inkwell shows an approval dialog first.", ["draft_id": str], required: ["draft_id"]),
        tool("archive", "Archive conversations.", ["thread_ids": ids], required: ["thread_ids"]),
        tool("mark_read", "Mark conversations read or unread.", ["thread_ids": ids, "read": bool], required: ["thread_ids"]),
        tool("flag", "Flag or unflag conversations.", ["thread_ids": ids, "flagged": bool], required: ["thread_ids"]),
        tool("move_to_folder", "Move conversations to a folder (not Trash or Spam).", ["thread_ids": ids, "folder": str], required: ["thread_ids", "folder"]),
        tool("remove_label", "Move conversations back to the inbox.", ["thread_ids": ids], required: ["thread_ids"]),
        tool("snooze", "Snooze conversations until an ISO-8601 date/time.", ["thread_ids": ids, "until": str], required: ["thread_ids", "until"]),
        tool("mute", "Mute conversations so new replies skip the inbox.", ["thread_ids": ids], required: ["thread_ids"]),
        tool("remind_if_no_reply", "Bring a conversation back if nobody replies within N days.", ["thread_id": str, "days": int], required: ["thread_id", "days"]),
        tool("create_folder", "Create a folder.", ["account": str, "name": str], required: ["account", "name"]),
        tool("create_rule", "Create a mail rule (asks the user). field: from|subject|body|hasAttachment|mailingList. action: move|archive|markRead.",
             ["name": str, "field": str, "value": str, "action": str, "folder": str, "account": str], required: ["field", "action"]),
        tool("unsubscribe", "Unsubscribe from the mailing list a message came from (asks the user).", ["message_id": str], required: ["message_id"]),
        tool("block_sender", "Block a sender (asks the user).", ["email": str], required: ["email"]),
        tool("list_scheduled", "List messages scheduled to send later.", [:]),
        tool("list_rules", "List mail rules.", [:]),
        tool("get_activity", "List recent actions AI apps took in Inkwell.", ["limit": int]),
    ]

    // MARK: tool implementations

    private struct ToolError: LocalizedError { let errorDescription: String? ; init(_ s: String) { errorDescription = s } }

    private func call(_ name: String, _ a: [String: Any]) throws -> Any {
        let accounts = allowedAccounts()
        let acctSQL = accounts.isEmpty ? "''" : accounts.map { "'\($0.id.uuidString)'" }.joined(separator: ",")
        let redact = settings.hideOneTimeCodesFromAI
        func limit(_ d: Int) -> Int { min(max(a["limit"] as? Int ?? d, 1), 200) }
        func accountMatch(_ s: String?) -> Account? {
            guard let s, !s.isEmpty else { return nil }
            return accounts.first { $0.id.uuidString == s || $0.email.caseInsensitiveCompare(s) == .orderedSame || $0.label.caseInsensitiveCompare(s) == .orderedSame }
        }
        func threadIds() throws -> [String] {
            guard let t = a["thread_ids"] as? [String], !t.isEmpty else { throw ToolError("thread_ids required") }
            for id in t { guard accounts.contains(where: { id.hasPrefix($0.id.uuidString + "|") }) else { throw ToolError("Unknown thread \(id)") } }
            return t
        }

        switch name {
        case "list_accounts":
            return accounts.map { ["account": $0.email, "label": $0.label, "name": $0.displayName, "aliases": $0.aliases.map(\.email)] }
        case "list_folders":
            guard let acct = accountMatch(a["account"] as? String) else { throw ToolError("Unknown account") }
            return db.folders(account: acct.id).filter(\.selectable).map { ["path": $0.path, "name": MUTF7.decode($0.displayName), "role": $0.role.rawValue] }
        case "list_threads":
            let mailbox = (a["mailbox"] as? String ?? "inbox")
            var clause = "account IN (\(acctSQL))"
            var args: [Any?] = []
            if let acct = accountMatch(a["account"] as? String) { clause += " AND account=?"; args.append(acct.id.uuidString) }
            switch mailbox.lowercased() {
            case "inbox": clause += " AND folder='INBOX'"
            case "to_reply": clause += " AND folder='INBOX' AND needs_reply=1 AND answered=0"
            case "flagged": clause += " AND flagged=1"
            case "primary": clause += " AND folder='INBOX' AND COALESCE(gm_cat, category)=0"
            case "updates": clause += " AND folder='INBOX' AND COALESCE(gm_cat, category)=1"
            case "promos": clause += " AND folder='INBOX' AND COALESCE(gm_cat, category)=2"
            case "snoozed": clause += " AND (account || '|' || thread_key) IN (SELECT account || '|' || thread_key FROM snoozes)"
            default: clause += " AND folder=?"; args.append(mailbox)
            }
            if a["unread_only"] as? Bool == true { clause += " AND seen=0" }
            let msgs = db.messages(where: clause, args, limit: 2000)
            var seen = Set<String>(); var rows: [[String: Any]] = []
            for m in msgs {
                let tid = m.accountId.uuidString + "|" + m.threadKey
                guard seen.insert(tid).inserted else { continue }
                rows.append(summary(m, threadId: tid, redact: redact))
                if rows.count >= limit(30) { break }
            }
            return rows
        case "search_messages":
            let q = a["query"] as? String ?? ""
            let parsed = MailStore.parseSearch(q)
            var clauses = ["account IN (\(acctSQL))"]; var args: [Any?] = []
            if !parsed.text.isEmpty {
                clauses.append("id IN (SELECT id FROM msg_fts WHERE msg_fts MATCH ?)")
                args.append(parsed.text.split(separator: " ").map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }.joined(separator: " "))
            }
            if let f = parsed.from { clauses.append("(from_email LIKE ? OR from_name LIKE ?)"); args += ["%\(f)%", "%\(f)%"] }
            if let t = parsed.to { clauses.append("to_json LIKE ?"); args.append("%\(t)%") }
            if let s = parsed.subject { clauses.append("subject LIKE ?"); args.append("%\(s)%") }
            if parsed.hasAttachment { clauses.append("has_attach=1") }
            if parsed.unread { clauses.append("seen=0") }
            return db.messages(where: clauses.joined(separator: " AND "), args, limit: limit(25)).map { summary($0, threadId: $0.accountId.uuidString + "|" + $0.threadKey, redact: redact) }
        case "get_thread":
            guard let tid = a["thread_id"] as? String, let bar = tid.firstIndex(of: "|") else { throw ToolError("thread_id required") }
            let acct = String(tid[..<bar]), key = String(tid[tid.index(after: bar)...])
            guard accounts.contains(where: { $0.id.uuidString == acct }) else { throw ToolError("Unknown thread") }
            var seenMid = Set<String>()
            let msgs = db.messages(where: "account=? AND thread_key=?", [acct, key], limit: 100).reversed().filter { $0.messageId.isEmpty || seenMid.insert($0.messageId).inserted }
            return ["thread_id": tid, "messages": msgs.map { full($0, redact: redact) }]
        case "get_message":
            guard let mid = a["message_id"] as? String, let m = db.message(id: mid), accounts.contains(where: { $0.id == m.accountId }) else { throw ToolError("Message not found") }
            return full(m, redact: redact)
        case "find_attachments":
            let q = "%\(a["query"] as? String ?? "")%"
            return db.messages(where: "account IN (\(acctSQL)) AND has_attach=1 AND (attach_names LIKE ? OR from_email LIKE ? OR from_name LIKE ? OR subject LIKE ?)", [q, q, q, q], limit: limit(25)).map {
                ["message_id": $0.id, "thread_id": $0.accountId.uuidString + "|" + $0.threadKey, "attachments": $0.attachmentNames, "from": $0.from.formatted, "subject": $0.subject, "date": iso($0.date)]
            }
        case "find_contacts":
            return db.contacts(matching: a["query"] as? String ?? "", limit: 15).map { ["name": $0.name, "email": $0.email] }
        case "list_drafts":
            return localDrafts().map(draftJSON)
        case "create_draft":
            var d = OutgoingDraft()
            let acct = accountMatch(a["account"] as? String) ?? accounts.first
            d.accountId = acct?.id; d.fromEmail = acct?.email ?? ""
            if let rid = a["reply_to_message_id"] as? String, let m = db.message(id: rid) {
                d.accountId = m.accountId
                d.fromEmail = accounts.first { $0.id == m.accountId }?.email ?? d.fromEmail
                d.to = m.isFromMe ? m.to.map(\.formatted).joined(separator: ", ") : (m.replyTo.isEmpty ? m.from.formatted : m.replyTo)
                d.subject = m.subject.lowercased().hasPrefix("re:") ? m.subject : "Re: \(m.subject)"
                d.inReplyTo = m.messageId
                d.references = (m.references.split(separator: " ").map(String.init) + [m.messageId]).joined(separator: " ")
                d.replyThreadKey = m.threadKey
                d.replyToMessageId = m.id
            }
            if let to = a["to"] as? String { d.to = to }
            if let cc = a["cc"] as? String { d.cc = cc }
            if let s = a["subject"] as? String { d.subject = s }
            d.plain = a["body"] as? String ?? ""
            d.draftedBy = clientName
            saveDraft(d)
            queue("open_draft", ["draft_id": d.id.uuidString])
            return ["draft_id": d.id.uuidString, "status": "Draft created and shown in Inkwell. Use send_draft to ask the user to send it."]
        case "update_draft":
            guard let idS = a["draft_id"] as? String, var d = localDrafts().first(where: { $0.id.uuidString == idS }) else { throw ToolError("Draft not found") }
            if let to = a["to"] as? String { d.to = to }
            if let cc = a["cc"] as? String { d.cc = cc }
            if let s = a["subject"] as? String { d.subject = s }
            if let b = a["body"] as? String { d.plain = b; d.html = ""; d.rtfData = nil }
            d.draftedBy = clientName
            saveDraft(d)
            return ["draft_id": d.id.uuidString, "status": "updated"]
        case "send_draft":
            guard let idS = a["draft_id"] as? String, localDrafts().contains(where: { $0.id.uuidString == idS }) else { throw ToolError("Draft not found") }
            queue("send_draft", ["draft_id": idS])
            return "Inkwell is asking the user to approve sending this draft. It will not be sent unless they press Send."
        case "archive": queue("archive", ["thread_ids": try threadIds()]); return "Queued: archive. Applied when Inkwell is open."
        case "mark_read": queue("mark_read", ["thread_ids": try threadIds(), "read": a["read"] as? Bool ?? true]); return "Queued."
        case "flag": queue("flag", ["thread_ids": try threadIds(), "flagged": a["flagged"] as? Bool ?? true]); return "Queued."
        case "move_to_folder":
            let folder = a["folder"] as? String ?? ""
            let lower = folder.lowercased()
            if lower.contains("trash") || lower.contains("spam") || lower.contains("junk") || lower.contains("deleted") { throw ToolError("AI apps can't move mail to Trash or Spam.") }
            queue("move", ["thread_ids": try threadIds(), "folder": folder]); return "Queued."
        case "remove_label": queue("move", ["thread_ids": try threadIds(), "folder": "INBOX"]); return "Queued: moving back to Inbox."
        case "snooze":
            guard let u = a["until"] as? String, parseISO(u) != nil else { throw ToolError("until must be ISO-8601") }
            queue("snooze", ["thread_ids": try threadIds(), "until": u]); return "Queued."
        case "mute": queue("mute", ["thread_ids": try threadIds()]); return "Queued."
        case "remind_if_no_reply":
            guard let tid = a["thread_id"] as? String else { throw ToolError("thread_id required") }
            queue("remind", ["thread_id": tid, "days": a["days"] as? Int ?? 3]); return "Queued."
        case "create_folder":
            guard let acct = accountMatch(a["account"] as? String), let n = a["name"] as? String else { throw ToolError("account and name required") }
            queue("create_folder", ["account": acct.id.uuidString, "name": n]); return "Queued."
        case "create_rule":
            queue("create_rule", a); return "Asked the user to approve the rule in Inkwell."
        case "unsubscribe":
            queue("unsubscribe", ["message_id": a["message_id"] as? String ?? ""]); return "Asked the user to approve unsubscribing."
        case "block_sender":
            queue("block", ["email": a["email"] as? String ?? ""]); return "Asked the user to approve blocking."
        case "list_scheduled":
            return db.query("SELECT json FROM scheduled ORDER BY send_at") { $0.data(0) }.compactMap { $0.flatMap { try? JSONDecoder().decode(OutgoingDraft.self, from: $0) } }.map(draftJSON)
        case "list_rules":
            return settings.rules.map { ["name": $0.name, "field": $0.field.rawValue, "value": $0.value, "action": $0.action.rawValue, "enabled": $0.enabled] }
        case "get_activity":
            return db.query("SELECT ts, app, action, detail FROM ai_activity ORDER BY id DESC LIMIT \(limit(20))") {
                ["time": iso(Date(timeIntervalSince1970: $0.double(0))), "app": $0.string(1), "action": $0.string(2), "detail": $0.string(3)]
            }
        default:
            throw ToolError("Unknown tool \(name)")
        }
    }

    // MARK: helpers

    private func queue(_ action: String, _ args: [String: Any]) {
        let payload: [String: Any] = ["action": action, "args": args]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        db.exec("INSERT INTO pending_actions(app, json, created) VALUES(?,?,?)", [clientName, data, Date()])
    }

    private func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }
    private func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withFullDate]
        return f.date(from: s)
    }

    private func summary(_ m: MessageRecord, threadId: String, redact: Bool) -> [String: Any] {
        ["thread_id": threadId, "message_id": m.id, "from": m.from.formatted, "subject": m.subject, "date": iso(m.date),
         "snippet": redact ? Classifier.redactSecrets(m.snippet) : m.snippet, "unread": !m.seen, "flagged": m.flagged, "category": m.category.label,
         "has_attachments": m.hasAttachments, "folder": m.folder]
    }

    private func full(_ m: MessageRecord, redact: Bool) -> [String: Any] {
        let parsed = db.raw(for: m.id).map(MIME.parse)
        var body = parsed?.plainText ?? m.snippet + "\n[full body not downloaded yet: open it in Inkwell]"
        if redact { body = Classifier.redactSecrets(body) }
        return ["message_id": m.id, "from": m.from.formatted, "to": m.to.map(\.formatted).joined(separator: ", "), "cc": m.cc.map(\.formatted).joined(separator: ", "),
                "subject": m.subject, "date": iso(m.date), "body": String(body.prefix(30000)), "attachments": m.attachmentNames, "unread": !m.seen]
    }

    private func localDrafts() -> [OutgoingDraft] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.drafts, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { try? JSONDecoder().decode(OutgoingDraft.self, from: Data(contentsOf: $0)) }
    }

    private func saveDraft(_ d: OutgoingDraft) {
        if let data = try? JSONEncoder().encode(d) { try? data.write(to: Paths.drafts.appendingPathComponent(d.id.uuidString + ".json")) }
    }

    private func draftJSON(_ d: OutgoingDraft) -> [String: Any] {
        ["draft_id": d.id.uuidString, "from": d.fromEmail, "to": d.to, "cc": d.cc, "subject": d.subject, "body": d.plain,
         "send_at": d.sendAt.map(iso) ?? NSNull(), "drafted_by": d.draftedBy ?? NSNull()]
    }
}
