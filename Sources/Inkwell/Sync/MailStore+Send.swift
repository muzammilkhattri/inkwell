import Foundation
import AppKit

struct PendingSendApproval: Identifiable {
    let id = UUID()
    var draft: OutgoingDraft
    var app: String
    var actionId: Int
}

extension MailStore {
    // MARK: composing

    func identity(for accountId: UUID?, fromEmail: String) -> (Account, Alias?)? {
        guard let a = accountId.flatMap(account) ?? accounts.first else { return nil }
        let alias = a.aliases.first { $0.email.caseInsensitiveCompare(fromEmail) == .orderedSame }
        return (a, alias)
    }

    func signatureHTML(account a: Account, alias: Alias?, reply: Bool) -> String {
        if reply && !a.signatureOnReplies { return "" }
        let sig = (alias?.signature.isEmpty == false ? alias!.signature : a.signature)
        return sig.isEmpty ? "" : "\n\n-- \n" + sig
    }

    @discardableResult
    func compose(_ draft: OutgoingDraft? = nil, to: String = "", attachments: [URL] = []) -> UUID {
        var d = draft ?? OutgoingDraft()
        if draft == nil {
            let acct: Account? = {
                if case .accountInbox(let id) = mailbox { return account(id) }
                if case .folder(let id, _) = mailbox { return account(id) }
                return accounts.first
            }()
            d.accountId = acct?.id
            d.fromEmail = acct?.email ?? ""
            d.to = to
            d.attachments = attachments
            if let acct { d.plain = signatureHTML(account: acct, alias: nil, reply: false) }
        }
        drafts[d.id] = d
        if let open = openCompose { open(d.id) }
        return d.id
    }

    func replyDraft(to m: MessageRecord, parsed: ParsedMessage?, all: Bool) -> OutgoingDraft {
        let acct = account(m.accountId)
        var d = OutgoingDraft(accountId: m.accountId)
        // Reply from the address the mail was sent to.
        let recipients = (m.to + m.cc).map { $0.email.lowercased() }
        let alias = acct?.aliases.first { recipients.contains($0.email.lowercased()) }
        d.fromEmail = alias?.email ?? acct?.email ?? ""
        let mine = Set(acct?.allAddresses ?? [])
        var primary: [EmailAddress]
        if m.isFromMe { primary = m.to }
        else if !m.replyTo.isEmpty { primary = MIME.parseAddressList(m.replyTo) }
        else { primary = [m.from] }
        d.to = primary.map(\.formatted).joined(separator: ", ")
        if all {
            let others = (m.to + m.cc).filter { !mine.contains($0.email.lowercased()) && !primary.contains($0) }
            d.cc = others.map(\.formatted).joined(separator: ", ")
        }
        let subj = m.subject
        d.subject = subj.lowercased().hasPrefix("re:") ? subj : "Re: \(subj)"
        d.inReplyTo = m.messageId
        d.references = (m.references.split(separator: " ").map(String.init) + [m.messageId]).filter { !$0.isEmpty }.joined(separator: " ")
        d.replyThreadKey = m.threadKey
        d.replyToMessageId = m.id
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        let header = "On \(f.string(from: m.date)), \(m.from.display) <\(m.from.email)> wrote:"
        if let p = parsed {
            let quoted = p.html.isEmpty ? HTMLText.fromPlain(p.text) : p.html
            d.quotedHTML = "<div>\(HTMLText.escape(header))</div><blockquote style=\"margin:0 0 0 .8ex;border-left:2px solid #ccc;padding-left:1ex\">\(quoted)</blockquote>"
            d.quotedPlain = header + "\n" + p.plainText.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
        }
        if let acct { d.plain = signatureHTML(account: acct, alias: alias, reply: true) }
        return d
    }

    func forwardDraft(of m: MessageRecord, parsed: ParsedMessage?) -> OutgoingDraft {
        let acct = account(m.accountId)
        var d = OutgoingDraft(accountId: m.accountId)
        d.fromEmail = acct?.email ?? ""
        d.subject = m.subject.lowercased().hasPrefix("fwd:") ? m.subject : "Fwd: \(m.subject)"
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        let hdr = "---------- Forwarded message ----------\nFrom: \(m.from.formatted)\nDate: \(f.string(from: m.date))\nSubject: \(m.subject)\nTo: \(m.to.map(\.formatted).joined(separator: ", "))"
        if let p = parsed {
            d.quotedHTML = HTMLText.fromPlain(hdr) + "<br>" + (p.html.isEmpty ? HTMLText.fromPlain(p.text) : p.html)
            d.quotedPlain = hdr + "\n\n" + p.plainText
            // Carry attachments over via temp files.
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fwd-\(d.id.uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for a in p.visibleAttachments {
                if let url = try? SafeFile.writeUnique(a.data, named: a.filename, in: dir) { d.attachments.append(url) }
            }
        }
        if let acct { d.plain = signatureHTML(account: acct, alias: nil, reply: false) }
        return d
    }

    // MARK: sending with undo

    func queueSend(_ d: OutgoingDraft) {
        drafts[d.id] = nil
        deleteLocalDraft(d.id)
        if let at = d.sendAt, at > Date().addingTimeInterval(30) {
            if let json = try? JSONEncoder().encode(d) {
                db.exec("INSERT OR REPLACE INTO scheduled(id, json, send_at) VALUES(?,?,?)", [d.id.uuidString, json, at])
            }
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; f.doesRelativeDateFormatting = true
            showToast("Scheduled for \(f.string(from: at))") { [weak self] in
                self?.db.exec("DELETE FROM scheduled WHERE id=?", [d.id.uuidString])
                self?.drafts[d.id] = d
                self?.openCompose?(d.id)
            }
            return
        }
        let delay = max(0, settings.undoSendSeconds)
        let undo: () -> Void = { [weak self] in
            guard let self, let pending = self.pendingSends[d.id] else { return }
            pending.cancel()
            self.pendingSends[d.id] = nil
            if self.toast?.message.hasPrefix("Sending") == true { self.toast = nil; self.undoHandler = nil }
            self.drafts[d.id] = d
            self.openCompose?(d.id)
        }
        let task = Task { @MainActor in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            self.pendingSends[d.id] = nil
            do {
                try await self.deliver(d)
                Sounds.play(.swoosh)
                if self.toast?.message.hasPrefix("Sending") == true { self.toast = nil }
            } catch {
                self.drafts[d.id] = d
                self.showToast("Send failed: \(error.localizedDescription)", isError: true)
                self.openCompose?(d.id)
            }
        }
        pendingSends[d.id] = task
        if delay > 0 {
            showToast("Sending…", undo: undo, seconds: delay)
        }
    }

    /// Actually sends over SMTP and files a copy in Sent.
    func deliver(_ d: OutgoingDraft) async throws {
        guard let (acct, alias) = identity(for: d.accountId, fromEmail: d.fromEmail) else { throw MailError.protocolError("No account to send from") }
        let to = MIME.parseAddressList(d.to), cc = MIME.parseAddressList(d.cc), bcc = MIME.parseAddressList(d.bcc)
        guard !(to + cc + bcc).isEmpty else { throw MailError.protocolError("Add at least one recipient") }
        let from = EmailAddress(name: alias?.name.isEmpty == false ? alias!.name : acct.displayName, email: alias?.email ?? acct.email)
        var atts: [MIME.OutgoingAttachment] = []
        for u in d.attachments {
            guard let data = try? Data(contentsOf: u) else { continue }
            atts.append(.init(filename: u.lastPathComponent, mimeType: MIME.mimeType(for: u), data: data))
        }
        var extra: [(String, String)] = []
        if d.requestReadReceipt { extra.append(("Disposition-Notification-To", from.email)) }
        let html = "<html><body>\(d.html.isEmpty ? HTMLText.fromPlain(d.plain) : d.html)\(d.quotedHTML.isEmpty ? "" : "<br>" + d.quotedHTML)</body></html>"
        let text = d.plain + (d.quotedPlain.isEmpty ? "" : "\n\n" + d.quotedPlain)
        let (data, mid) = MIME.build(from: from, to: to, cc: cc, replyTo: alias?.replyTo, subject: d.subject, text: text, html: html,
                                     inReplyTo: d.inReplyTo.isEmpty ? nil : d.inReplyTo,
                                     references: d.references.split(separator: " ").map(String.init), attachments: atts, extraHeaders: extra)
        let password = Keychain.password(for: acct)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                do {
                    let smtp = try SMTPClient(host: acct.smtpHost, port: acct.smtpPort, security: acct.smtpSecurity)
                    try smtp.login(user: acct.username, password: password)
                    try smtp.sendMail(from: from.email, recipients: (to + cc + bcc).map(\.email), data: data)
                    smtp.quit()
                    cont.resume()
                } catch { cont.resume(throwing: error) }
            }
        }
        // Gmail and Microsoft file sent mail automatically.
        let autoFiles = acct.isGmail || acct.smtpHost.contains("office365") || acct.smtpHost.contains("outlook")
        if let conn = connections[acct.id] {
            if !autoFiles, let sent = acct.sentFolder {
                _ = try? await conn.run { c in try c.append(sent, flags: "\\Seen", message: data) }
            }
            if !d.replyToMessageId.isEmpty, let orig = db.message(id: d.replyToMessageId) {
                db.exec("UPDATE messages SET answered=1, needs_reply=0 WHERE id=?", [orig.id])
                _ = try? await conn.run { c in try c.select(orig.folder); try c.store("\(orig.uid)", flags: "\\Answered", add: true) }
            }
            if let draftMid = d.serverDraftMessageId { await deleteServerDraft(account: acct, messageId: draftMid) }
        }
        if let remind = d.remindAfter {
            let key = d.replyThreadKey.isEmpty ? (d.references.split(separator: " ").first.map(String.init) ?? mid) : d.replyThreadKey
            db.exec("INSERT OR REPLACE INTO reminders(account, thread_key, until, sent_date, subject) VALUES(?,?,?,?,?)",
                    [acct.id.uuidString, key, Date().addingTimeInterval(remind), Date(), d.subject])
        }
        for a in to + cc + bcc { db.noteContact(a, date: Date()) }
        sync(accountId: acct.id)
    }

    // MARK: drafts

    func saveLocalDraft(_ d: OutgoingDraft) {
        drafts[d.id] = d
        if let data = try? JSONEncoder().encode(d) { try? data.write(to: Paths.drafts.appendingPathComponent(d.id.uuidString + ".json")) }
    }

    func deleteLocalDraft(_ id: UUID) {
        try? FileManager.default.removeItem(at: Paths.drafts.appendingPathComponent(id.uuidString + ".json"))
    }

    func localDrafts() -> [OutgoingDraft] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.drafts, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { try? JSONDecoder().decode(OutgoingDraft.self, from: Data(contentsOf: $0)) }
    }

    /// Mirrors the draft into the account's Drafts folder (replacing the previous copy).
    func saveServerDraft(_ draft: OutgoingDraft) async -> OutgoingDraft {
        var d = draft
        guard let (acct, alias) = identity(for: d.accountId, fromEmail: d.fromEmail), let folder = acct.draftsFolder, let conn = connections[acct.id] else { return d }
        let old = d.serverDraftMessageId
        let mid = "draft-\(UUID().uuidString)@\(acct.email.split(separator: "@").last ?? "local")"
        let from = EmailAddress(name: alias?.name.isEmpty == false ? alias!.name : acct.displayName, email: alias?.email ?? acct.email)
        let html = (d.html.isEmpty ? HTMLText.fromPlain(d.plain) : d.html) + d.quotedHTML
        let (data, _) = MIME.build(from: from, to: MIME.parseAddressList(d.to), cc: MIME.parseAddressList(d.cc), replyTo: nil, subject: d.subject,
                                   text: d.plain, html: html, inReplyTo: d.inReplyTo.isEmpty ? nil : d.inReplyTo,
                                   references: d.references.split(separator: " ").map(String.init), attachments: [], messageId: mid)
        do {
            try await conn.run { c in try c.append(folder, flags: "\\Draft \\Seen", message: data) }
            d.serverDraftMessageId = mid
            if let old { await deleteServerDraft(account: acct, messageId: old) }
        } catch {}
        return d
    }

    func deleteServerDraft(account acct: Account, messageId: String) async {
        guard let folder = acct.draftsFolder, let conn = connections[acct.id] else { return }
        _ = try? await conn.run { c -> Void in
            try c.select(folder)
            let uids = try c.uidSearch("HEADER Message-ID \(IMAPClient.quote("<\(messageId)>"))")
            if !uids.isEmpty { try c.expunge(IMAPClient.uidSet(uids)) }
        }
    }

    func scheduledDrafts() -> [OutgoingDraft] {
        db.query("SELECT json FROM scheduled ORDER BY send_at") { $0.data(0) }.compactMap { $0.flatMap { try? JSONDecoder().decode(OutgoingDraft.self, from: $0) } }
    }

    func cancelScheduled(_ d: OutgoingDraft) {
        db.exec("DELETE FROM scheduled WHERE id=?", [d.id.uuidString])
        var copy = d; copy.sendAt = nil
        drafts[d.id] = copy
        openCompose?(d.id)
    }

    // MARK: calendar replies

    func respond(to invite: CalendarInvite, message m: MessageRecord, response: CalendarInvite.Response) async {
        guard let acct = account(m.accountId), let organizer = invite.organizer else { return }
        let recipients = (m.to + m.cc).map { $0.email.lowercased() }
        let me = acct.aliases.first { recipients.contains($0.email.lowercased()) }.map { EmailAddress(name: $0.name, email: $0.email) }
            ?? EmailAddress(name: acct.displayName, email: acct.email)
        let ics = invite.replyICS(attendee: me, response: response)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("invite-\(UUID().uuidString).ics")
        try? Data(ics.utf8).write(to: url)
        var d = OutgoingDraft(accountId: acct.id)
        d.fromEmail = me.email
        d.to = organizer.formatted
        d.subject = "\(response.verb): \(invite.summary)"
        d.plain = "\(me.display) has \(response.verb.lowercased()) this invitation."
        d.attachments = [url]
        d.inReplyTo = m.messageId
        do { try await deliver(d); showToast("\(response.verb) sent to \(organizer.display)") }
        catch { showToast("Couldn't send reply: \(error.localizedDescription)", isError: true) }
    }
}
