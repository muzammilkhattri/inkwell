import Foundation

/// On-device heuristics: smart tabs, To Reply detection, one-time codes, phishing checks.
enum Classifier {
    private static let promoWords = ["sale", "% off", " off ", "deal", "offer", "discount", "shop now", "limited time", "coupon", "promo", "free shipping", "save ", "black friday",
        "exclusive", "new arrivals", "webinar", "don't miss", "unlocked", "airdrop", "bonus", "reward", "giveaway", "free", "launch", "introducing", "is here", "is live",
        "new feature", "now available", "newsletter", "weekly", "monthly", "digest", "recap", "roundup", "edition", "top posts", "what's new", "announcing", "event",
        "join us", "register", "last chance", "ends soon", "waiting", "%", "tutorial", "posts", "episode", "podcast", "course"]
    private static let noReplyMarkers = ["noreply", "no-reply", "donotreply", "do-not-reply", "notifications", "notification", "alerts", "mailer-daemon", "bounce", "updates@", "news@", "newsletter", "info@", "hello@", "team@", "support@", "billing@", "marketing"]
    private static let bulkHeaders = ["X-Mailchimp", "X-Campaign", "X-MC-User", "X-SG-EID", "X-Mailgun", "X-SES-Outgoing", "X-Marketo", "X-HubSpot", "X-Klaviyo", "X-Braze", "Feedback-ID",
        "X-Auto-Response-Suppress", "X-Report-Abuse", "X-CSA-Complaints", "X-Mandrill-User", "X-PM-Message-Id", "X-SFMC-Stack", "X-Postmark"]

    /// Mailboxes run by companies, not people ("service@bank.com", "safety@shopco.com").
    private static let roleLocalParts: Set<String> = ["service", "services", "customerservice", "customercare", "care", "help", "helpdesk",
        "account", "accounts", "statement", "statements", "receipt", "receipts", "order", "orders", "payment", "payments", "billing",
        "security", "safety", "trust", "verify", "verification", "auth", "notify", "notice", "notices", "alert", "reminder", "reminders",
        "mail", "email", "mailer", "contact", "hello", "hey", "hi", "team", "news", "info", "learning", "events", "community",
        "feedback", "admin", "system", "automated", "postmaster", "contacto", "kontakt", "contato", "membership", "members", "marketing", "promo", "offers", "store", "shop"]
    /// Sending subdomains used by bulk/transactional mail ("email.apple.com", "mail.company.com").
    private static let bulkSubdomains: Set<String> = ["email", "mail", "e", "em", "news", "info", "notify", "notification", "notifications",
        "mailer", "bounce", "mg", "sg", "marketing", "updates", "alerts", "comms", "messages", "txn", "transactional"]

    static func isAutomated(_ from: EmailAddress, headers: [(String, String)]) -> Bool {
        let e = from.email.lowercased()
        // "no_reply", "no.reply", "do-not-reply" all normalise to the same marker.
        let squashed = e.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: ".", with: "").replacingOccurrences(of: "-", with: "")
        if noReplyMarkers.contains(where: { e.has($0) || squashed.has($0.replacingOccurrences(of: "-", with: "")) }) { return true }
        let local = String(e.split(separator: "@").first ?? "")
        let localWord = local.split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? local
        if roleLocalParts.contains(local) || roleLocalParts.contains(localWord) { return true }
        let labels = from.domain.split(separator: ".")
        if labels.count >= 3, let sub = labels.first, bulkSubdomains.contains(String(sub)) { return true }
        func has(_ n: String) -> Bool { headers.contains { $0.0.caseInsensitiveCompare(n) == .orderedSame } }
        if has("List-Unsubscribe") || has("List-Id") { return true }
        let prec = headers.first { $0.0.lowercased() == "precedence" }?.1.lowercased() ?? ""
        if prec == "bulk" || prec == "list" || prec == "junk" { return true }
        let auto = headers.first { $0.0.lowercased() == "auto-submitted" }?.1.lowercased() ?? ""
        if !auto.isEmpty && auto != "no" { return true }
        return bulkHeaders.contains(where: has)
    }

    /// Transactional / notification vocabulary → Updates. Anything else bulk → Promos.
    private static let transactionalWords = ["receipt", "order", "invoice", "shipped", "shipping", "delivered", "delivery", "out for delivery", "refund", "cancelled", "canceled",
        "payment", "paid", "charge", "statement", "bill", "subscription renew", "renewal", "trial", "booking", "reservation", "itinerary", "check-in", "boarding",
        "ticket", "confirmed", "confirmation", "security", "sign-in", "sign in", "signed in", "login", "log in", "password", "verification", "verify", "verify your",
        "one-time", "code", "2fa", "two-factor", "new device", "alert", "account", "access", "invitation", "invited", "commented", "mentioned", "replied", "assigned",
        "pull request", "merged", "deploy", "build failed", "build passed", "incident", "outage", "disclosure", "rotate", "expires", "expiring", "action required",
        "your report", "export is ready", "has been"]

    /// Whole-word / whole-phrase match, so "Xcode" doesn't count as "code" or "freedom" as "free".
    static func containsTerm(_ hay: String, _ term: String) -> Bool {
        let t = term.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, hay.has(t) else { return false }
        if t.first.map({ !$0.isLetter && !$0.isNumber }) == true { return true }   // "% off" etc.
        var search = hay.startIndex..<hay.endIndex
        while let r = hay.range(of: t, range: search) {
            let before = r.lowerBound == hay.startIndex ? nil : hay[hay.index(before: r.lowerBound)]
            let after = r.upperBound == hay.endIndex ? nil : hay[r.upperBound]
            let okBefore = before.map { !$0.isLetter && !$0.isNumber } ?? true
            let okAfter = after.map { !$0.isLetter && !$0.isNumber } ?? true
            if okBefore && okAfter { return true }
            search = r.upperBound..<hay.endIndex
        }
        return false
    }

    static func category(from: EmailAddress, subject: String, text: String, headers: [(String, String)]) -> MailCategory {
        guard isAutomated(from, headers: headers) else { return .primary }
        let subj = subject.lowercased()
        let body = String(text.prefix(500)).lowercased()
        let promoHit = promoWords.contains { containsTerm(subj, $0) } || promoWords.filter { containsTerm(body, $0) }.count >= 2
        let subjectTransactional = transactionalWords.contains { containsTerm(subj, $0) }
        if subjectTransactional && !promoHit { return .updates }
        func has(_ n: String) -> Bool { headers.contains { $0.0.caseInsensitiveCompare(n) == .orderedSame } }
        let bulk = has("List-Unsubscribe") || has("List-Id") || bulkHeaders.contains(where: has)
        if promoHit || bulk { return subjectTransactional ? .updates : .promos }
        // Automated but not a mailing list (e.g. noreply notifications) → Updates.
        return .updates
    }

    private static let requestPhrases = ["can you", "could you", "would you", "will you", "please", "let me know", "lmk", "what do you think", "thoughts?", "are you", "do you", "any update", "when can", "when will", "is it possible", "would it be", "need your", "waiting for", "get back to me", "your thoughts", "confirm", "rsvp"]
    /// Boilerplate lines ("Questions? Contact us", "Please do not reply") that aren't asking the reader anything.
    private static let boilerplate = ["contact us", "do not reply", "don't reply", "not monitored", "unsubscribe", "privacy", "help center", "help centre",
        "customer service", "customer support", "call us", "faq", "if you did not", "if you didn't", "if this wasn't you", "if this was not you",
        "terms", "manage your", "view in browser", "view online", "questions?", "need help", "all rights reserved", "this email was sent", "you received this"]

    /// True if this (incoming, human) message looks like it's waiting on the user.
    static func needsReply(from: EmailAddress, isFromMe: Bool, category: MailCategory, text: String, headers: [(String, String)]) -> Bool {
        guard !isFromMe, category == .primary, !isAutomated(from, headers: headers) else { return false }
        let lines = HTMLText.stripQuoted(text).lowercased().split(separator: "\n").map(String.init)
            .filter { line in !boilerplate.contains { line.contains($0) } }
        let body = String(lines.joined(separator: "\n").prefix(2000))
        guard !body.isEmpty else { return false }
        // Whole words, so "confirmed" or "pleased" don't read as a request.
        return body.contains("?") || requestPhrases.contains { containsTerm(body, $0) }
    }

    // MARK: One-time codes & magic links

    /// The mail must be about signing in or verifying something at all.
    private static let otpContext = try! NSRegularExpression(pattern:
        #"(?i)\b(?:otp|passcode|2fa|mfa|one[- ]time|verif\w*|authenticat\w*|security code|confirm\w*|sign[- ]?in|log[- ]?in|access code|pin)\b"#)
    private static let codeWord = try! NSRegularExpression(pattern: #"(?i)\b(?:code|otp|passcode|pin)\b"#)
    private static let candidate = try! NSRegularExpression(pattern: #"(?<![0-9A-Za-z])([0-9]{3}[- ][0-9]{3}|[0-9]{4,8}|[A-Z0-9]{6,8})(?![0-9A-Za-z])"#)
    /// "482913 is your Foo code", "315542 - Your Tunely login code", "G-482913 is your Google verification code".
    private static let codeFirst = try! NSRegularExpression(pattern:
        #"(?<![0-9A-Za-z.,/:+#$])(?<![0-9]-)([0-9]{4,8}|[0-9]{3}[- ][0-9]{3})[^\S\n]*(?:[-–—:|]|is\b)[^\S\n]*(?i:your|the)\b[^\n.]{0,40}?\b(?i:code|otp|pin|passcode)\b"#)
    private static let ownLine = try! NSRegularExpression(pattern: #"(?m)^[^\S\n]*([0-9]{3}[- ][0-9]{3}|[0-9]{4,8}|[A-Z0-9]{6,8})[^\S\n]*$"#)
    private static let lastWord = try! NSRegularExpression(pattern: #"([A-Za-z]+)[^A-Za-z]*$"#)
    /// "promo code", "invite code", "zip code"… are codes, just not sign-in codes.
    private static let notSignInCode: Set<String> = ["promo", "promotional", "discount", "coupon", "voucher", "referral", "invite", "invitation", "gift",
        "zip", "postal", "post", "area", "country", "dialing", "source", "qr", "error", "status", "tracking", "order", "booking", "reference", "ref",
        "product", "sort", "swift", "bank", "branch", "tax", "dress", "bar", "color", "colour", "html", "css", "sample", "example", "offer", "sale"]
    private static let httpsLink = try! NSRegularExpression(pattern: #"https://[^\s"'<>]+"#)

    /// Only numbers sitting right next to a sign-in phrase count ("code is 482913", "482913 is your
    /// code", a code alone on its line under "Your verification code"). A bare 6-digit number
    /// anywhere in a login-ish mail is usually a phone number, CVE id, PO box or ticket number.
    static func oneTimeCode(subject: String, text: String) -> String? {
        let hay = subject + "\n" + text.prefix(3000)
        let ns = hay as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard otpContext.firstMatch(in: hay, range: full) != nil else { return nil }

        for m in codeFirst.matches(in: hay, range: full) {
            if let c = validCode(ns, m.range(at: 1)) { return c }
        }
        for k in codeWord.matches(in: hay, range: full) where !isOtherKindOfCode(ns, keywordAt: k.range.location) {
            let start = NSMaxRange(k.range)
            for c in candidate.matches(in: hay, range: NSRange(location: start, length: min(80, ns.length - start))) {
                // Words between keyword and code are fine ("code for signing in to Acme is"), but not
                // other numbers or a sentence break ("code. Call 0700 1234567").
                let glue = ns.substring(with: NSRange(location: start, length: c.range.location - start))
                if glue.count > 50 || glue.rangeOfCharacter(from: .decimalDigits) != nil || [". ", "? ", "! "].contains(where: glue.contains) { break }
                if let code = validCode(ns, c.range(at: 1)) { return code }
            }
        }
        for m in ownLine.matches(in: hay, range: full) {
            let lo = max(0, m.range.location - 300)
            let before = NSRange(location: lo, length: m.range.location - lo)
            guard let k = codeWord.matches(in: hay, range: before).last,
                  !isOtherKindOfCode(ns, keywordAt: k.range.location) else { continue }
            if let c = validCode(ns, m.range(at: 1)) { return c }
        }
        return nil
    }

    private static func isOtherKindOfCode(_ ns: NSString, keywordAt loc: Int) -> Bool {
        let lo = max(0, loc - 24)
        let before = ns.substring(with: NSRange(location: lo, length: loc - lo))
        guard let m = lastWord.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) else { return false }
        return notSignInCode.contains((before as NSString).substring(with: m.range(at: 1)).lowercased())
    }

    /// Rejects numbers that are one piece of something longer (phone numbers, versions, decimals,
    /// times, CVE ids, "021 111 222"), years, prices and letter-only words.
    private static func validCode(_ ns: NSString, _ r: NSRange) -> String? {
        guard r.location != NSNotFound, r.length > 0 else { return nil }
        let code = ns.substring(with: r)
        func at(_ i: Int) -> unichar? { i >= 0 && i < ns.length ? ns.character(at: i) : nil }
        func isDigit(_ c: unichar?) -> Bool { c.map { $0 >= 48 && $0 <= 57 } ?? false }
        let joiners = Set(".,:/-+".utf16)
        let b1 = at(r.location - 1), b2 = at(r.location - 2)
        let a1 = at(NSMaxRange(r)), a2 = at(NSMaxRange(r) + 1)
        if isDigit(b1) || isDigit(a1) { return nil }
        if let b1, joiners.contains(b1), isDigit(b2) { return nil }
        if let a1, joiners.contains(a1), isDigit(a2) { return nil }
        if let b1, Set("+#$€£¥".utf16).contains(b1) { return nil }
        if a1 == 37 { return nil } // %
        if b1 == 32 && isDigit(b2) { return nil }
        if a1 == 32 && isDigit(a2) { return nil }

        let compact = code.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        let digits = compact.filter(\.isNumber).count
        guard digits > 0 else { return nil }
        if compact.count == 4 && digits == 4 && (compact.hasPrefix("19") || compact.hasPrefix("20")) { return nil }
        if digits < compact.count && compact.count < 6 { return nil }
        return compact
    }

    static func magicLink(subject: String, html: String, text: String) -> URL? {
        let lower = (subject + " " + text.prefix(800)).lowercased()
        guard ["sign in", "sign-in", "log in", "login", "magic link", "verify your email", "confirm your email"].contains(where: { lower.contains($0) }) else { return nil }
        let source = html.isEmpty ? text : html
        let candidates = httpsLink.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { Range($0.range, in: source).map { String(source[$0]) } }
        let hit = candidates.first { c in let l = c.lowercased(); return ["login", "signin", "sign-in", "magic", "verify", "auth", "token", "confirm"].contains { l.contains($0) } }
        return hit.flatMap { URL(string: HTMLText.decodeEntities($0)) }
    }

    enum SignIn: Equatable {
        case code(String)
        case link(URL)
    }

    /// A code wins over a link: code emails often also contain a "sign in" button.
    static func signIn(subject: String, html: String, text: String) -> SignIn? {
        if let c = oneTimeCode(subject: subject, text: text) { return .code(c) }
        if let l = magicLink(subject: subject, html: html, text: text) { return .link(l) }
        return nil
    }

    /// Replace codes & sign-in links before handing mail to AI apps.
    static func redactSecrets(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: #"\b[0-9]{4,8}\b"#, with: "[code hidden]", options: .regularExpression)
        out = out.replacingOccurrences(of: #"https?://\S*(login|signin|sign-in|magic|verify|token|auth|reset)\S*"#, with: "[sign-in link hidden]", options: [.regularExpression, .caseInsensitive])
        return out
    }

    // MARK: Phishing & impersonation

    private static let brands: [String: [String]] = [
        "paypal": ["paypal.com"], "apple": ["apple.com", "icloud.com", "me.com"], "microsoft": ["microsoft.com", "outlook.com", "live.com", "office.com"],
        "google": ["google.com", "gmail.com", "youtube.com"], "amazon": ["amazon.com", "amazon.co.uk", "amazon.de", "amazonses.com"],
        "netflix": ["netflix.com"], "facebook": ["facebook.com", "facebookmail.com", "meta.com"], "instagram": ["instagram.com", "mail.instagram.com"],
        "chase": ["chase.com"], "wells fargo": ["wellsfargo.com"], "bank of america": ["bankofamerica.com"], "dhl": ["dhl.com"], "fedex": ["fedex.com"],
        "ups": ["ups.com"], "coinbase": ["coinbase.com"], "binance": ["binance.com"], "dropbox": ["dropbox.com"], "docusign": ["docusign.net", "docusign.com"],
        "linkedin": ["linkedin.com"], "stripe": ["stripe.com"], "github": ["github.com"],
    ]

    struct PhishingVerdict { var warning: String }

    static func phishingCheck(from: EmailAddress, headers: [(String, String)]) -> PhishingVerdict? {
        let domain = from.domain
        let name = from.name.lowercased()
        func rootMatches(_ d: String, _ allowed: [String]) -> Bool { allowed.contains { d == $0 || d.hasSuffix("." + $0) } }
        if domain.hasPrefix("xn--") || domain.contains(".xn--") {
            return PhishingVerdict(warning: "The sender's domain (\(domain)) uses look-alike international characters.")
        }
        for (brand, domains) in brands {
            if name.contains(brand) && !rootMatches(domain, domains) && !isESP(domain) {
                return PhishingVerdict(warning: "This message claims to be from \(brand.capitalized) but was sent from \(domain).")
            }
            for d in domains {
                let label = d.split(separator: ".").first.map(String.init) ?? d
                let dl = domain.split(separator: ".").dropLast().joined(separator: ".")
                if dl != label && !rootMatches(domain, domains) && levenshtein(String(dl.split(separator: ".").last ?? ""), label) == 1 && label.count > 4 {
                    return PhishingVerdict(warning: "The sender's domain \(domain) looks similar to \(d).")
                }
            }
        }
        let auth = headers.first { $0.0.lowercased() == "authentication-results" }?.1.lowercased() ?? ""
        if auth.contains("dmarc=fail") || (auth.contains("spf=fail") && auth.contains("dkim=fail")) {
            return PhishingVerdict(warning: "This message failed sender verification (DMARC). The sender may not be who they claim.")
        }
        return nil
    }

    private static func isESP(_ d: String) -> Bool {
        ["sendgrid.net", "mailchimp.com", "mcsv.net", "amazonses.com", "mailgun.org", "sparkpostmail.com"].contains { d.hasSuffix($0) }
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }; if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}
