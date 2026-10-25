import Foundation

/// `Inkwell --selftest`: quick checks of the protocol/MIME parsers without a mail server.
private extension MessageRecord {
    func withId(_ id: String) -> MessageRecord { var m = self; m.id = id; return m }
}

enum SelfTest {
    static func run() -> Never {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print((ok ? "✓ " : "✗ ") + name)
            if !ok { failures += 1 }
        }

        // IMAP response parsing with a literal
        let fetch = Data("* 3 FETCH (UID 42 FLAGS (\\Seen \\Flagged) RFC822.SIZE 120 BODY[HEADER] {21}\r\nSubject: Hi there\r\n\r\n)".utf8)
        let v = IMAPParser.parse(fetch)
        let kv = v.count > 3 ? v[3].list ?? [] : []
        check("IMAP fetch tokens", v.count == 4 && kv.count == 8)
        check("IMAP literal body", kv.count == 8 && kv[7].text == "Subject: Hi there\r\n\r\n")
        check("IMAP flags list", kv.count > 3 && kv[3].list?.compactMap(\.text) == ["\\Seen", "\\Flagged"])
        let partial = IMAPClient.parseFetch([Data("* 1 FETCH (UID 9 RFC822.SIZE 5 BODY[HEADER] {4}\r\nA: b BODY[]<0> {5}\r\nhello)".utf8)])
        check("IMAP partial body literal", partial.first?.uid == 9 && partial.first?.body == Data("hello".utf8) && partial.first?.header == Data("A: b".utf8))
        let list = IMAPParser.parse(Data("* LIST (\\HasNoChildren \\Sent) \"/\" \"[Gmail]/Sent Mail\"".utf8))
        check("IMAP LIST", list.count == 5 && list[4].text == "[Gmail]/Sent Mail" && list[2].list?.count == 2)
        check("UID set", IMAPClient.uidSet([5, 1, 2, 3, 9, 10]) == "1:3,5,9:10")
        check("Modified UTF-7", MUTF7.decode("&ZeVnLIqe-") == "日本語" && MUTF7.encode("Entwürfe") == "Entw&APw-rfe")

        // MIME
        check("Encoded word B", MIME.decodeHeader("=?UTF-8?B?w6l0w6k=?=") == "été")
        check("Encoded word Q", MIME.decodeHeader("=?iso-8859-1?Q?caf=E9_cr=E8me?=") == "café crème")
        check("Adjacent encoded words", MIME.decodeHeader("=?UTF-8?Q?a?= =?UTF-8?Q?b?=") == "ab")
        let addrs = MIME.parseAddressList("\"Doe, Jane\" <jane@x.com>, bob@y.org, =?UTF-8?Q?Ren=C3=A9?= <rene@z.fr>")
        check("Address list", addrs.count == 3 && addrs[0].name == "Doe, Jane" && addrs[1].email == "bob@y.org" && addrs[2].name == "René")
        check("RFC2822 date", MIME.parseDate("Tue, 3 Jun 2025 10:22:01 +0200 (CEST)") != nil)
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        let samples = ["Tue, 3 Jun 2025 10:22:01 +0200", "Mon, 29 Feb 2024 23:59:59 -0730", "Sat, 1 Jan 2000 00:00:00 +0000", "Wed, 31 Dec 2025 12:00:00 +1400"]
        check("Fast date parser matches DateFormatter", samples.allSatisfy { MIME.fastParseDate($0) == df.date(from: $0) })
        check("Fast date parser variants", MIME.fastParseDate("3 Jun 2025 10:22 GMT") == df.date(from: "Tue, 3 Jun 2025 10:22:00 +0000")
              && MIME.fastParseDate("Tue, 03 Jun 25 10:22:01 EDT") == df.date(from: "Tue, 3 Jun 2025 10:22:01 -0400"))

        let raw = """
        From: Alice <alice@example.com>\r
        To: me@example.com\r
        Subject: =?UTF-8?Q?Caf=C3=A9?=\r
        Message-ID: <abc@example.com>\r
        References: <root@example.com> <mid@example.com>\r
        MIME-Version: 1.0\r
        Content-Type: multipart/mixed; boundary="XX"\r
        \r
        --XX\r
        Content-Type: multipart/alternative; boundary="YY"\r
        \r
        --YY\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        Hello caf=C3=A9, can you send the =\r
        file?\r
        --YY\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <p>Hello <b>café</b></p><img src="https://t.example.com/open?id=1" width="1" height="1">\r
        --YY--\r
        --XX\r
        Content-Type: application/pdf; name="report.pdf"\r
        Content-Disposition: attachment; filename*=UTF-8''r%C3%A9port.pdf\r
        Content-Transfer-Encoding: base64\r
        \r
        JVBERi0xLjQK\r
        --XX\r
        Content-Type: text/calendar; method=REQUEST; charset=utf-8\r
        \r
        BEGIN:VCALENDAR\r
        METHOD:REQUEST\r
        BEGIN:VEVENT\r
        UID:evt1\r
        SUMMARY:Design review\r
        DTSTART:20260301T150000Z\r
        DTEND:20260301T160000Z\r
        ORGANIZER;CN=Alice:mailto:alice@example.com\r
        ATTENDEE;CN=Me:mailto:me@example.com\r
        END:VEVENT\r
        END:VCALENDAR\r
        --XX--\r

        """
        let p = MIME.parse(Data(raw.utf8))
        check("Subject decode", p.subject == "Café")
        check("QP text + soft break", p.text.contains("Hello café, can you send the file?"))
        check("HTML part", p.html.contains("<b>café</b>"))
        check("Attachment RFC2231 name", p.attachments.first?.filename == "réport.pdf" && p.attachments.first?.data.prefix(4) == Data("%PDF".utf8))
        check("References", p.references == ["root@example.com", "mid@example.com"])
        let inv = p.calendar.flatMap(CalendarInvite.parse)
        check("Calendar invite", inv?.summary == "Design review" && inv?.organizer?.email == "alice@example.com" && inv?.start != nil)
        check("Thread key uses root", SyncEngine.threadKey(messageId: p.messageId, inReplyTo: "", references: p.references, subject: "", gmThread: nil) == "root@example.com")
        let clean = Privacy.clean(p.html)
        check("Tracking pixel removed", clean.trackersRemoved == 1 && !clean.html.contains("open?id"))
        check("UTM stripped", Privacy.stripParams("https://a.com/x?utm_source=n&id=5") == "https://a.com/x?id=5")

        // Classifier
        check("Needs reply", Classifier.needsReply(from: EmailAddress(name: "Alice", email: "alice@example.com"), isFromMe: false, category: .primary, text: p.text, headers: p.headers))
        check("OTP", Classifier.oneTimeCode(subject: "Your verification code", text: "Your code is 482913. It expires soon.") == "482913")
        let otpCases: [(String, String, String?)] = [
            ("315542 - Your Tunely login code", "Hi,", "315542"),
            ("431801 is your ShopCo sign-in code", "Use it to sign in", "431801"),
            ("G-482913 is your Google verification code", "", "482913"),
            ("Acme Verification Code", "Your Acme verification code : M36Q23. If you did not", "M36Q23"),
            ("Your Nimbus Login Code", "Your Nimbus login code - 449602   Use this code to log in", "449602"),
            ("", "Your OTP is: 627472", "627472"),
            ("Sign in to Acme", "Enter this code to sign in:\n\n   482 913\n\nIt expires in 10 minutes.", "482913"),
            ("Critical PHP Vulnerabilities (CVE-2026-109618 and CVE-2026-109619)", "Update to PHP 8.3.12 now. Log in to your dashboard.", nil),
            ("Acme Bank Mobile App Login Alert", "call our 24/7 helpline at +44 20 111-331-331 /111-331-332 to block", nil),
            ("Verify your number", "We'll call you on 0700 1234567 or +44 700 1234567 to confirm.", nil),
            ("Welcome to Orbit", "Use invite code 865821 to get early access. Sign in now.", nil),
            ("Your order is confirmed", "Pos No: 140041. Your request (174930) has been updated. PO Box 410777", nil),
            ("Sign in to Sketchpad", "ABN 80 158 929 938", nil),
            ("Log in to see your stats", "Use promo code SAVE2025 for 20% off", nil),
        ]
        for (s, t, want) in otpCases {
            let got = Classifier.oneTimeCode(subject: s, text: t)
            check("OTP \(want ?? "none") ← \(s.isEmpty ? String(t.prefix(30)) : String(s.prefix(30))) (got \(got ?? "none"))", got == want)
        }
        check("Promo category", Classifier.category(from: EmailAddress(name: "Shop", email: "news@shop.com"), subject: "50% off sale ends tonight", text: "", headers: [("List-Unsubscribe", "<mailto:u@shop.com>")]) == .promos)
        check("Update category", Classifier.category(from: EmailAddress(name: "Bank", email: "noreply@bank.com"), subject: "Your statement is ready", text: "", headers: []) == .updates)
        check("Brand impersonation", Classifier.phishingCheck(from: EmailAddress(name: "PayPal Support", email: "help@secure-pay.xyz"), headers: []) != nil)
        check("Legit brand", Classifier.phishingCheck(from: EmailAddress(name: "PayPal", email: "service@paypal.com"), headers: []) == nil)

        // Build → parse round trip
        let (built, _) = MIME.build(from: EmailAddress(name: "Zoë", email: "z@x.com"), to: [EmailAddress(name: "", email: "a@b.com")], cc: [], replyTo: nil,
                                    subject: "Grüße", text: "hi ✓", html: "<p>hi ✓</p>", inReplyTo: "abc@x.com", references: ["abc@x.com"],
                                    attachments: [.init(filename: "a.txt", mimeType: "text/plain", data: Data("file".utf8))])
        let rt = MIME.parse(built)
        check("Round trip", rt.subject == "Grüße" && rt.text == "hi ✓" && rt.html == "<p>hi ✓</p>" && rt.attachments.first?.data == Data("file".utf8) && rt.from.name == "Zoë")

        var junk = ParsedMessage()
        junk.text = "[image: Google] App password created. See [proxyco logo](https://www.proxyco.example/) at https://list.example.com/track?e=4 ---- * { font-family: 'Avenir'; color: red; } Hello there"
        let snip = HTMLText.snippet(junk)
        check("Snippet cleaned (\(snip))", snip == "App password created. See proxyco logo at Hello there")
        check("Newsletter → Promos", Classifier.category(from: EmailAddress(name: "ModelLab", email: "news@modellab.example"), subject: "Our new model: Vista-1 is here!", text: "", headers: [("List-Unsubscribe", "<x>")]) == .promos)
        check("Order → Updates", Classifier.category(from: EmailAddress(name: "QuickEats", email: "no-reply@quickeats.example"), subject: "Your order has been placed.", text: "", headers: [("List-Unsubscribe", "<x>")]) == .updates)
        check("Security alert → Updates", Classifier.category(from: EmailAddress(name: "Google", email: "no-reply@accounts.google.com"), subject: "Security alert", text: "", headers: []) == .updates)
        check("Xcode is not a code", Classifier.category(from: EmailAddress(name: "SwiftCasts", email: "no-reply@creators.example"), subject: "Header Scroll Effect Using SwiftUI | Xcode 27", text: "", headers: [("List-Unsubscribe", "<x>")]) == .promos)
        // --- audit regressions (2026-10-24) ---
        // S02: a huge year in a sender's Date header must be rejected, not overflow.
        _ = MIME.parseDate("Tue, 3 Jun 9223372036854775807 10:22:01 +0200")  // full parser path: must not trap
        check("Date: fast parser rejects absurd year", MIME.fastParseDate("Tue, 3 Jun 9223372036854775807 10:22:01 +0200") == nil)
        check("Date: absurd zone rejected", MIME.fastParseDate("Tue, 3 Jun 2025 10:22:01 +9999") == nil)
        check("Date: normal still parses", MIME.fastParseDate("Tue, 3 Jun 2025 10:22:01 +0200") != nil)
        // S03: emails nested inside emails share one depth budget.
        var nested = Data("Subject: inner\r\nContent-Type: text/plain\r\n\r\ndeepest\r\n".utf8)
        for _ in 0..<3000 { nested = Data("Content-Type: message/rfc822\r\n\r\n".utf8) + nested }
        let t0 = Date(); _ = MIME.parse(nested)
        check("MIME: 3,000 nested message/rfc822 parts parse quickly without crashing", Date().timeIntervalSince(t0) < 1)
        var shallow = Data("Content-Type: text/plain\r\n\r\nhello\r\n".utf8)
        for _ in 0..<3 { shallow = Data("Content-Type: message/rfc822\r\n\r\n".utf8) + shallow }
        check("MIME: shallow forwarded email still yields its text (\(MIME.parse(shallow).text.debugDescription))", MIME.parse(shallow).text.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
        // S09: avatar colour index for any address, including extreme code points.
        let odd = ["", "a@b.c", String(repeating: "\u{10FFFF}", count: 500) + "@x", String(repeating: "zz", count: 4000)]
        check("Avatar colour index always in range", odd.allSatisfy { (0..<8).contains(AvatarView.pastelIndex($0)) })
        // S04: attachment names can't leave the folder they're saved to.
        let safeDir = FileManager.default.temporaryDirectory.appendingPathComponent("safefile-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: safeDir, withIntermediateDirectories: true)
        let names = ["../escape.txt", "../../etc/x", "/abs/path.txt", "..", ".hidden", "a\u{0}b.txt", "", "ok.pdf", "ok.pdf"]
        let written = names.compactMap { try? SafeFile.writeUnique(Data("x".utf8), named: $0, in: safeDir) }
        let inside = written.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL.path == safeDir.standardizedFileURL.path }
        check("Attachment names stay inside the folder (\(written.map(\.lastPathComponent)))", written.count == names.count && inside
              && Set(written.map(\.lastPathComponent)).count == names.count)
        try? FileManager.default.removeItem(at: safeDir)
        // S08: CR/LF from an incoming subject or name never starts a new outgoing header.
        let (evil, _) = MIME.build(from: EmailAddress(name: "Me\r\nX-Injected: 1", email: "me@x.com"), to: [EmailAddress(name: "", email: "a@b.com")], cc: [],
                                   replyTo: nil, subject: "Re: hi\r\nBcc: victim@x.com", text: "t", html: "", inReplyTo: nil, references: [], attachments: [])
        let evilHead = String(decoding: MIME.splitHeaderBody(evil).0, as: UTF8.self)
        check("Outgoing headers can't be injected", !evilHead.contains("\r\nX-Injected") && !evilHead.contains("\r\nBcc"))
        // S12: lookalike domains get the link warning.
        check("Link warning: attackerpaypal.com ≠ paypal.com", !LinkOpener.sameSite("attackerpaypal.com", "paypal.com"))
        check("Link warning: mail.paypal.com ~ paypal.com", LinkOpener.sameSite("mail.paypal.com", "paypal.com"))
        // C02: the row cache returns complete results across its eviction threshold.
        let dbPath = NSTemporaryDirectory() + "cachetest-\(UUID().uuidString).sqlite"
        let cdb = Database(path: dbPath)
        let acct = UUID()
        for i in 0..<300 {
            cdb.upsert(MessageRecord(id: "m\(i)", accountId: acct, folder: "INBOX", uid: UInt32(i), messageId: "m\(i)@x", inReplyTo: "", references: "",
                                     threadKey: "t\(i)", from: EmailAddress(name: "S", email: "s@x.com"), to: [], cc: [], replyTo: "", subject: "s\(i)",
                                     date: Date(timeIntervalSince1970: Double(i) * 60), snippet: "", seen: false, flagged: false, answered: false, size: 1,
                                     category: .primary, needsReply: false, listUnsubscribe: "", listUnsubscribePost: "", hasAttachments: false,
                                     hasBody: false, isFromMe: false, attachmentNames: ""))
        }
        let savedLimit = Database.rowCacheLimit; Database.rowCacheLimit = 100
        for lo in [0, 80, 160] { _ = cdb.messagesCached(where: "uid >= \(lo) AND uid < \(lo + 80)", limit: 80) }
        cdb.exec("UPDATE messages SET flagged=1 WHERE id='m5'")
        let cached = cdb.messagesCached(where: "uid < 80", limit: 80), fresh = cdb.messages(where: "uid < 80", limit: 80)
        Database.rowCacheLimit = savedLimit
        check("Row cache complete after eviction (\(cached.count)/\(fresh.count))", cached == fresh && cached.count == 80)
        // C03: a body that finishes downloading keeps newer flags and never revives a deleted row.
        let stale = cdb.messages(where: "id='m10'", limit: 1)[0]
        cdb.exec("UPDATE messages SET seen=1, flagged=1 WHERE id='m10'")
        let bodyAcct = Account(label: "T", displayName: "T", email: "t@x.com", username: "t", imapHost: "x", smtpHost: "x")
        let bodyRaw = Data("Subject: s10\r\nContent-Type: text/plain\r\n\r\nCan you review this?\r\n".utf8)
        SyncEngine.applyBody(bodyRaw, to: stale, account: bodyAcct, db: cdb)
        let after = cdb.messages(where: "id='m10'", limit: 1).first
        check("Body download keeps newer read/flag state", after?.seen == true && after?.flagged == true && after?.hasBody == true)
        cdb.deleteMessage(id: "m11")
        SyncEngine.applyBody(bodyRaw, to: cdb.messages(where: "id='m12'", limit: 1)[0].withId("m11"), account: bodyAcct, db: cdb)
        check("Body download doesn't revive a deleted email", cdb.messages(where: "id='m11'", limit: 1).isEmpty && cdb.raw(for: "m11") == nil)
        try? FileManager.default.removeItem(atPath: dbPath)

        // C01: a busy account can't push another account (or its unread mail) out of the list.
        let capPath = NSTemporaryDirectory() + "captest-\(UUID().uuidString).sqlite"
        let capDB = Database(path: capPath)
        let busyAcct = UUID(), quietAcct = UUID()
        func rec(_ i: Int, _ a: UUID, seen: Bool, age: Double) -> MessageRecord {
            MessageRecord(id: "\(a.uuidString)-\(i)", accountId: a, folder: "INBOX", uid: UInt32(i), messageId: "", inReplyTo: "", references: "",
                          threadKey: "\(a.uuidString)-t\(i)", from: EmailAddress(name: "S", email: "s@x.com"), to: [], cc: [], replyTo: "", subject: "s",
                          date: Date(timeIntervalSince1970: 2_000_000_000 - age), snippet: "", seen: seen, flagged: false, answered: false, size: 1,
                          category: .primary, needsReply: false, listUnsubscribe: "", listUnsubscribePost: "", hasAttachments: false,
                          hasBody: false, isFromMe: false, attachmentNames: "")
        }
        capDB.transaction {
            for i in 0..<5200 { capDB.upsert(rec(i, busyAcct, seen: i % 2 == 0 || i < 5000, age: Double(i))) }   // newest, plus 100 old unread
            for i in 0..<300 { capDB.upsert(rec(i, quietAcct, seen: false, age: 1_000_000 + Double(i))) }        // older, all unread
        }
        let window = MailStore.inboxWindow(ids: "'\(busyAcct.uuidString)','\(quietAcct.uuidString)'", db: capDB)
        let quietRows = window.filter { $0.accountId == quietAcct }.count
        let busyOldUnread = window.filter { $0.accountId == busyAcct && !$0.seen && $0.uid >= 5000 }.count
        check("Inbox list keeps a quieter account (\(quietRows)/300) and old unread mail (\(busyOldUnread)/100)", quietRows == 300 && busyOldUnread == 100)
        try? FileManager.default.removeItem(atPath: capPath)

        let helo = SMTPClient.heloName
        check("EHLO name is valid ASCII hostname (\(helo))", helo == "[127.0.0.1]" || helo.range(of: "^[a-z0-9.-]+$", options: .regularExpression) != nil)

        print(failures == 0 ? "\nAll checks passed" : "\n\(failures) check(s) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
