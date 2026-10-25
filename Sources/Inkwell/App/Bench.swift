import Foundation

/// `INKWELL_HOME=/tmp/x Inkwell --bench`: builds a large synthetic mailbox and times hot paths.
@MainActor
enum Bench {
    static func time(_ label: String, iterations: Int = 1, _ body: () -> Void) {
        body() // warm-up
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { body() }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 / Double(iterations)
        print(String(format: "%-44@ %10.3f ms", label as NSString, ms))
    }

    static func newsletterHTML(_ i: Int) -> String {
        var s = "<html><head><style>.x{color:red}</style></head><body><table width=\"100%\" bgcolor=\"#f4f4f4\">"
        for j in 0..<60 {
            s += "<tr><td style=\"padding:12px;font-family:Helvetica\"><h2>Story \(j) of issue \(i)</h2><p>Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore &amp; dolore magna aliqua.</p>"
            s += "<a href=\"https://news.example.com/story/\(j)?utm_source=newsletter&utm_medium=email&id=\(j)\">Read more</a>"
            s += "<img src=\"https://cdn.example.com/img/\(j).jpg\" width=\"560\" height=\"300\"></td></tr>"
        }
        s += "<img src=\"https://t.example.com/open?u=\(i)\" width=\"1\" height=\"1\"></table></body></html>"
        return s
    }

    static func rawMessage(_ i: Int, html: Bool) -> Data {
        var s = "From: =?UTF-8?Q?Ren=C3=A9_Sender_\(i % 300)?= <sender\(i % 300)@company\(i % 40).com>\r\nTo: Me <me@example.com>\r\n"
        s += "Subject: =?UTF-8?B?\(Data("Project update #\(i) — café".utf8).base64EncodedString())?=\r\nDate: Tue, 3 Jun 2025 10:22:01 +0200\r\n"
        s += "Message-ID: <m\(i)@ex.com>\r\nMIME-Version: 1.0\r\n"
        if html {
            s += "Content-Type: multipart/alternative; boundary=\"b\"\r\n\r\n--b\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n"
            s += String(repeating: "Hello there, this is line of plain text with caf=C3=A9 and a soft =\r\nbreak.\r\n", count: 80)
            s += "--b\r\nContent-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
            s += Data(newsletterHTML(i).utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]) + "\r\n--b--\r\n"
        } else {
            s += "Content-Type: text/plain; charset=utf-8\r\n\r\nHi,\r\nCan you take a look at the project update before Friday? Let me know what you think.\r\n\r\nThanks!\r\n\r\nOn Mon, Jun 2, 2025 at 9:00 AM Me <me@example.com> wrote:\r\n"
            s += String(repeating: "> quoted earlier text line\r\n", count: 40)
        }
        return Data(s.utf8)
    }

    /// `INKWELL_INSECURE_LOCAL=1 Inkwell --synctest <port>` against scripts' fake IMAP server.
    static func syncTest() -> Never {
        let port = Int(CommandLine.arguments.last ?? "") ?? 1143
        var acct = Account(label: "Test", displayName: "Me", email: "me@example.com", username: "me", imapHost: "127.0.0.1", smtpHost: "127.0.0.1")
        acct.imapPort = port
        let db = Database.shared
        if let b = ProcessInfo.processInfo.environment["PREFETCH_BATCH"].flatMap(Int.init) { SyncEngine.prefetchBatchMax = b }
        func measure(_ label: String, _ body: () throws -> Int) {
            let b0 = MailSocket.bytesRead
            let t0 = DispatchTime.now().uptimeNanoseconds
            let n = (try? body()) ?? -1
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            print(String(format: "%-40@ %9.1f ms %9.1f KB  (%d new)", label as NSString, ms, Double(MailSocket.bytesRead - b0) / 1024, n))
        }
        do {
            let c = try IMAPClient(host: "127.0.0.1", port: port)
            try c.login(user: "me", password: "x")
            print("server CONDSTORE:", c.supportsCondstore)
            measure("initial sync (300 newest + bodies)") { _ = try SyncEngine.syncFolders(c, account: &acct, db: db); return try SyncEngine.syncFolder(c, account: acct, path: "INBOX", db: db).count }
            measure("re-sync, nothing changed") { try SyncEngine.syncFolder(c, account: acct, path: "INBOX", db: db).count }
            try c.select("INBOX")
            let top = try c.uidSearch("UID 1:*").max() ?? 1
            try c.store("\(top)", flags: "\\Flagged", add: true)
            measure("re-sync, 1 flag changed") { try SyncEngine.syncFolder(c, account: acct, path: "INBOX", db: db).count }
            let flagged = db.query("SELECT COUNT(*) FROM messages WHERE flagged=1") { $0.int(0) }.first ?? 0
            print("flag change applied locally:", flagged == 1)

            // Deletion on the server must still be noticed now that the UID list is skipped
            // when the message count adds up.
            let victim = top - 5
            try c.command("X-DELETE \(victim)")
            try c.store("\(top)", flags: "\\Flagged", add: false)
            measure("re-sync, 1 deleted remotely") { try SyncEngine.syncFolder(c, account: acct, path: "INBOX", db: db).count }
            let gone = (db.query("SELECT COUNT(*) FROM messages WHERE folder='INBOX' AND uid=?", [Int(victim)]) { $0.int(0) }.first ?? 1) == 0
            print("remote delete applied locally:", gone)
            try c.command("X-INJECT"); try c.command("X-DELETE \(victim - 1)")
            measure("re-sync, 1 new + 1 deleted") { try SyncEngine.syncFolder(c, account: acct, path: "INBOX", db: db).count }
            let gone2 = (db.query("SELECT COUNT(*) FROM messages WHERE folder='INBOX' AND uid=?", [Int(victim - 1)]) { $0.int(0) }.first ?? 1) == 0
            print("delete hidden by new arrival applied:", gone2)

            measure("unread backlog, pass 1") { try SyncEngine.syncUnread(c, account: acct, path: "INBOX", db: db) }
            measure("unread backlog, pass 2") { try SyncEngine.syncUnread(c, account: acct, path: "INBOX", db: db) }
            let serverUnread = try c.uidSearch("UNSEEN")
            let localUnread = db.query("SELECT COUNT(*) FROM messages WHERE folder='INBOX' AND seen=0") { $0.int(0) }.first ?? 0
            print("all server unread present locally:", localUnread == serverUnread.count, "(\(localUnread)/\(serverUnread.count))")
            if let oldest = serverUnread.min() {
                try c.store("\(oldest)", flags: "\\Seen", add: true)
                measure("unread reconcile after remote read") { try SyncEngine.syncUnread(c, account: acct, path: "INBOX", db: db) }
                let seen = db.query("SELECT seen FROM messages WHERE folder='INBOX' AND uid=?", [Int(oldest)]) { $0.bool(0) }.first ?? false
                print("remote read applied outside sync window:", seen)
            }
        } catch { print("sync test failed:", error.localizedDescription) }
        exit(0)
    }

    static func run() -> Never {
        let n = Int(ProcessInfo.processInfo.environment["BENCH_N"] ?? "") ?? 20000
        print("Inkwell benchmark — \(n) messages, data in \(Paths.appSupport.path)\n")
        let a1 = Account(label: "Personal", displayName: "Me", email: "me@example.com", username: "me", imapHost: "imap.invalid", smtpHost: "smtp.invalid")
        var a2 = Account(label: "Work", displayName: "Me", email: "me@work.com", username: "me", imapHost: "imap.invalid", smtpHost: "smtp.invalid")
        a2.colorHex = "#22B07D"
        var settings = AppSettings(); settings.accounts = [a1, a2]
        SettingsStore.save(settings)
        let db = Database.shared

        // --- insert throughput (simulates sync writing headers)
        var records: [MessageRecord] = []
        let now = Date().timeIntervalSince1970
        for i in 0..<n {
            let acct = i % 3 == 0 ? a2 : a1
            let folder = i % 7 == 0 ? "Sent" : (i % 5 == 0 ? "Archive" : "INBOX")
            let fromMe = folder == "Sent"
            let thread = "t\(i / 3)@ex.com"
            let from = fromMe ? EmailAddress(name: "Me", email: acct.email) : EmailAddress(name: "Sender \(i % 300)", email: "sender\(i % 300)@company\(i % 40).com")
            records.append(MessageRecord(id: "\(acct.id.uuidString)|\(folder)|1|\(i)", accountId: acct.id, folder: folder, uid: UInt32(i), messageId: "m\(i)@ex.com",
                                         inReplyTo: "", references: "", threadKey: thread, from: from,
                                         to: [EmailAddress(name: "Me", email: acct.email), EmailAddress(name: "Other Person", email: "other@x.com")], cc: [],
                                         replyTo: "", subject: "Project update #\(i / 3)", date: Date(timeIntervalSince1970: now - Double(i) * 600),
                                         snippet: "Can you take a look at the project update before Friday? Let me know what you think.",
                                         seen: i % 4 != 0, flagged: i % 50 == 0, answered: false, size: 4000,
                                         category: MailCategory(rawValue: i % 3) ?? .primary, needsReply: i % 9 == 0, listUnsubscribe: i % 3 == 2 ? "<https://u.example.com>" : "",
                                         listUnsubscribePost: "", hasAttachments: i % 11 == 0, hasBody: true, isFromMe: fromMe, attachmentNames: i % 11 == 0 ? "report.pdf" : ""))
        }
        let t0 = DispatchTime.now().uptimeNanoseconds
        db.transaction { for r in records { db.upsert(r, bodyText: r.snippet + " body text for search " + r.subject) } }
        let insertMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        print(String(format: "%-44@ %10.3f ms  (%.1f µs/msg)", "insert \(n) messages (1 txn)" as NSString, insertMs, insertMs * 1000 / Double(n)))

        let raws = (0..<400).map { rawMessage($0, html: $0 % 2 == 0) }
        db.transaction { for (i, r) in raws.enumerated() { db.setRaw(r, for: records[i].id) } }

        // --- store-level
        let store = MailStore.shared
        print("")
        time("reload() All Inboxes", iterations: 10) { store.mailbox = .allInboxes; store.reloadNow() }
        print("   threads:", store.threads.count)
        time("reload() Primary tab", iterations: 10) { store.tab = .primary; store.reloadNow() }
        store.tab = .all
        time("reload() To Reply", iterations: 10) { store.mailbox = .toReply; store.reloadNow() }
        time("reload() Flagged", iterations: 10) { store.mailbox = .flagged; store.reloadNow() }
        store.mailbox = .allInboxes; store.reloadNow()
        store.mailbox = .allInboxes; store.tab = .all
        let q = MailStore.ListQuery(accountIds: store.accountIdsSQL, mailbox: .allInboxes, tab: .all, unreadOnly: false, blocked: [], muted: [])
        var r: MailStore.ListResult?
        time("  └ computeList (now off main thread)", iterations: 10) { r = MailStore.computeList(q, db: db) }
        _ = r
        let ids = store.accountIdsSQL
        time("  └ query inbox rows (5000)", iterations: 10) { _ = db.messages(where: "folder='INBOX' AND account IN (\(ids))", limit: 5000) }
        time("  └ query inbox rows, cached (nothing changed)", iterations: 10) { _ = db.messagesCached(where: "folder='INBOX' AND account IN (\(ids))", limit: 5000) }
        time("  └ query inbox rows, cached (50 changed)", iterations: 10) {
            for m in records.prefix(50) { db.exec("UPDATE messages SET flagged=1-flagged WHERE id=?", [m.id]) }
            _ = db.messagesCached(where: "folder='INBOX' AND account IN (\(ids))", limit: 5000)
        }
        // The cache must never serve a stale row: change flags, a tab, a body, delete one, re-insert it.
        for m in records.prefix(30) { db.exec("UPDATE messages SET seen=1-seen, gm_cat=2 WHERE id=?", [m.id]) }
        db.exec("UPDATE messages SET snippet='changed', needs_reply=1 WHERE id=?", [records[0].id])
        db.deleteMessage(id: records[1].id)
        var back = records[1]; back.subject = "re-inserted"; back.seen.toggle(); db.upsert(back)
        let fresh = db.messages(where: "folder='INBOX' AND account IN (\(ids))", limit: 5000)
        let cached = db.messagesCached(where: "folder='INBOX' AND account IN (\(ids))", limit: 5000)
        print("   cached rows identical to a fresh read:", fresh == cached, "(\(cached.count) rows)")
        let tg = DispatchTime.now().uptimeNanoseconds
        var grouped = 0
        for _ in 0..<10 { grouped += MailStore.group(db.messagesCached(where: "folder='INBOX' AND account IN (\(ids))", limit: 5000), bumps: [:]).count }
        print(String(format: "%-44@ %10.3f ms", "  └ cached rows + group()" as NSString, Double(DispatchTime.now().uptimeNanoseconds - tg) / 10_000_000))
        time("  └ query inbox rows, raw SQL only", iterations: 10) { _ = db.query("SELECT id FROM messages WHERE folder='INBOX' AND account IN (\(ids)) ORDER BY date DESC LIMIT 5000") { $0.int(0) } }
        time("  └ sent-per-thread GROUP BY", iterations: 10) { _ = db.query("SELECT account, thread_key, MAX(date) FROM messages WHERE from_me=1 GROUP BY account, thread_key") { $0.string(0) + "|" + $0.string(1) } }
        time("  └ WidgetBridge.publish", iterations: 10) { WidgetBridge.publish(store: store, inboxThreads: store.threads) }
        let sample = Array(store.threads.prefix(200))
        time("conversation() ×200", iterations: 3) { for t in sample { _ = store.conversation(t) } }
        time("localSearch(\"project friday\")", iterations: 20) { _ = store.localSearch("project friday") }
        time("localSearch(\"from:sender12 has:attachment\")", iterations: 20) { _ = store.localSearch("from:sender12 has:attachment") }
        time("tick() (scheduler, nothing due)", iterations: 10) { store.tick() }
        time("setSeen local update ×50 (+reload)", iterations: 1) {
            for r in records.prefix(50) { store.db.exec("UPDATE messages SET seen=? WHERE id=?", [true, r.id]) }; store.reloadNow()
        }

        // --- parsing
        print("")
        time("MIME.parse ×400 (half 25KB newsletters)", iterations: 3) { for r in raws { _ = MIME.parse(r) } }
        let parsed = raws.map(MIME.parse)
        let htmls = parsed.map(\.html).filter { !$0.isEmpty }
        time("Privacy.clean ×200 newsletters (uncached)", iterations: 3) { for h in htmls { _ = Privacy.cleanUncached(h) } }
        time("Privacy.clean ×200 newsletters (re-render)", iterations: 3) { for h in htmls { _ = Privacy.clean(h) } }
        time("HTMLText.toPlain ×200 newsletters", iterations: 3) { for h in htmls { _ = HTMLText.toPlain(h) } }
        time("ParsedMessage.plainText ×400", iterations: 3) { for p in parsed { _ = p.plainText } }
        let texts = parsed.map(\.text)
        time("HTMLText.stripQuoted ×400", iterations: 3) { for t in texts { _ = HTMLText.stripQuoted(t) } }
        time("SyncEngine.applyBody ×100 (parse+classify+write)", iterations: 1) {
            db.transaction { for i in 0..<100 { SyncEngine.applyBody(raws[i], to: records[i], account: a1, db: db) } }
        }
        time("Classifier.oneTimeCode ×5000", iterations: 1) { for i in 0..<5000 { _ = Classifier.oneTimeCode(subject: "Your verification code", text: "Code \(i % 999999) expires") } }
        time("MIME.decodeHeader ×20000", iterations: 1) { for i in 0..<20000 { _ = MIME.decodeHeader("=?UTF-8?Q?Ren=C3=A9_\(i)?= <x@y.com>") } }
        let hdr = MIME.splitHeaderBody(raws[1]).0
        time("  └ parseHeaders ×5000", iterations: 1) { for _ in 0..<5000 { _ = MIME.parseHeaders(hdr) } }
        time("  └ parseDate ×5000", iterations: 1) { for _ in 0..<5000 { _ = MIME.parseDate("Tue, 3 Jun 2025 10:22:01 +0200") } }
        let hs = MIME.parseHeaders(hdr)
        time("  └ Classifier.category ×5000", iterations: 1) { for _ in 0..<5000 { _ = Classifier.category(from: EmailAddress(name: "A", email: "a@b.com"), subject: "Project update", text: "", headers: hs) } }
        time("parseHeaders + record() ×5000", iterations: 1) {
            for i in 0..<5000 { _ = SyncEngine.record(fetch: FetchResult(uid: UInt32(i), flags: ["\\Seen"]), header: hdr, account: a1, folder: "INBOX", uidValidity: 1) }
        }

        // --- protocol
        print("")
        var fetchBlob = Data()
        for i in 0..<300 {
            let h = MIME.splitHeaderBody(raws[i]).0 + Data("\r\n\r\n".utf8)
            fetchBlob += Data("* \(i + 1) FETCH (UID \(i + 1) FLAGS (\\Seen) INTERNALDATE \"03-Jun-2025 10:22:01 +0200\" RFC822.SIZE 4000 BODY[HEADER] {\(h.count)}\r\n".utf8) + h + Data(")\r\n".utf8)
        }
        for i in 0..<150 { // bodies
            let b = raws[i]
            fetchBlob += Data("* \(i + 1) FETCH (UID \(i + 1) BODY[] {\(b.count)}\r\n".utf8) + b + Data(")\r\n".utf8)
        }
        print("   simulated server stream: \(fetchBlob.count / 1024) KB")
        time("LineReader+literals: read 450 FETCH responses", iterations: 3) {
            var off = 0
            let r = LineReader { guard off < fetchBlob.count else { throw MailError.closed }; let e = min(off + 65536, fetchBlob.count); defer { off = e }; return fetchBlob.subdata(in: off..<e) }
            var responses: [Data] = []
            while let line = try? r.readLine() {
                var out = line
                while out.last == 125, let open = out.lastIndex(of: 123), let n = Int(String(decoding: out[(open + 1)..<(out.endIndex - 1)], as: UTF8.self)) {
                    out.append(contentsOf: [13, 10]); out.append((try? r.readBytes(n)) ?? Data()); out.append((try? r.readLine()) ?? Data())
                }
                responses.append(out)
            }
        }
        let lines: [Data] = {
            var res: [Data] = []
            for i in 0..<300 {
                let h = MIME.splitHeaderBody(raws[i]).0 + Data("\r\n\r\n".utf8)
                res.append(Data("* \(i + 1) FETCH (UID \(i + 1) FLAGS (\\Seen) RFC822.SIZE 4000 BODY[HEADER] {\(h.count)}\r\n".utf8) + h + Data(")".utf8))
            }
            return res
        }()
        time("IMAPParser.parse ×300 header FETCH", iterations: 3) { for l in lines { _ = IMAPParser.parse(l) } }

        print("\ndone")
        exit(0)
    }
}
