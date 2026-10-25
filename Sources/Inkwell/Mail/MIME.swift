import Foundation

struct MIMEPartAttachment: Identifiable, Hashable {
    var id = UUID()
    var filename: String
    var mimeType: String
    var data: Data
    var contentId: String?
    var inline: Bool
}

struct ParsedMessage {
    var headers: [(String, String)] = []
    var text: String = ""
    var html: String = ""
    var attachments: [MIMEPartAttachment] = []
    var calendar: String?

    func header(_ name: String) -> String {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1 ?? ""
    }
    var subject: String { MIME.decodeHeader(header("Subject")) }
    var from: EmailAddress { MIME.parseAddressList(header("From")).first ?? EmailAddress(name: "", email: "") }
    var to: [EmailAddress] { MIME.parseAddressList(header("To")) }
    var cc: [EmailAddress] { MIME.parseAddressList(header("Cc")) }
    var date: Date? { MIME.parseDate(header("Date")) }
    var messageId: String { MIME.cleanId(header("Message-ID")) }
    var inReplyTo: String { MIME.cleanId(header("In-Reply-To")) }
    var references: [String] { MIME.idList(header("References")) }
    var visibleAttachments: [MIMEPartAttachment] { attachments.filter { !$0.inline || $0.contentId == nil } }

    /// Best plain text for snippets/AI.
    var plainText: String {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        return HTMLText.toPlain(html)
    }
}

enum MIME {
    // MARK: headers

    static func splitHeaderBody(_ data: Data) -> (Data, Data) {
        if let r = data.firstRange(of: Data([13, 10, 13, 10])) {
            return (data.subdata(in: data.startIndex..<r.lowerBound), data.subdata(in: r.upperBound..<data.endIndex))
        }
        if let r = data.firstRange(of: Data([10, 10])) {
            return (data.subdata(in: data.startIndex..<r.lowerBound), data.subdata(in: r.upperBound..<data.endIndex))
        }
        return (data, Data())
    }

    static func parseHeaders(_ data: Data) -> [(String, String)] {
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        var out: [(String, String)] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.isEmpty { continue }
            if (line.first == " " || line.first == "\t"), !out.isEmpty {
                out[out.count - 1].1 += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let c = line.firstIndex(of: ":") {
                out.append((String(line[..<c]).trimmingCharacters(in: .whitespaces), String(line[line.index(after: c)...]).trimmingCharacters(in: .whitespaces)))
            }
        }
        return out
    }

    /// Parses `type/subtype; a=b; c="d"` → (lowercased type, params lowercased keys)
    static func parseParams(_ value: String) -> (String, [String: String]) {
        var parts: [String] = []
        var cur = ""; var inQ = false
        for ch in value {
            if ch == "\"" { inQ.toggle(); cur.append(ch); continue }
            if ch == ";" && !inQ { parts.append(cur); cur = ""; continue }
            cur.append(ch)
        }
        parts.append(cur)
        let main = parts.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        var params: [String: String] = [:]
        var continuations: [String: [(Int, String)]] = [:]
        for p in parts.dropFirst() {
            guard let eq = p.firstIndex(of: "=") else { continue }
            var k = p[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var v = p[p.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 { v = String(v.dropFirst().dropLast()) }
            // RFC 2231: name*=utf-8''..., name*0*=...
            var encoded = false
            if k.hasSuffix("*") { k.removeLast(); encoded = true }
            if let star = k.firstIndex(of: "*"), let n = Int(k[k.index(after: star)...]) {
                let base = String(k[..<star])
                continuations[base, default: []].append((n, encoded ? rfc2231(v, first: n == 0) : v))
                continue
            }
            params[k] = encoded ? rfc2231(v, first: true) : v
        }
        for (k, chunks) in continuations { params[k] = chunks.sorted { $0.0 < $1.0 }.map(\.1).joined() }
        return (main, params)
    }

    private static func rfc2231(_ v: String, first: Bool) -> String {
        var s = v
        var charset = "utf-8"
        if first {
            let parts = v.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count == 3 { charset = String(parts[0]); s = String(parts[2]) }
        }
        let bytes = percentDecodeBytes(s)
        return decodeCharset(Data(bytes), charset: charset.isEmpty ? "utf-8" : charset)
    }

    private static func percentDecodeBytes(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        let u = Array(s.utf8)
        var i = 0
        while i < u.count {
            if u[i] == 37, i + 2 < u.count, let b = UInt8(String(decoding: u[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) { out.append(b); i += 3 }
            else { out.append(u[i]); i += 1 }
        }
        return out
    }

    static func encoding(for charset: String) -> String.Encoding {
        let cs = charset.lowercased().trimmingCharacters(in: .whitespaces)
        if cs.isEmpty || cs == "utf-8" || cs == "utf8" || cs == "us-ascii" { return .utf8 }
        let cf = CFStringConvertIANACharSetNameToEncoding(cs as CFString)
        if cf == kCFStringEncodingInvalidId { return .utf8 }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    static func decodeCharset(_ data: Data, charset: String) -> String {
        if let s = String(data: data, encoding: encoding(for: charset)) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    private static let encodedWord = try! NSRegularExpression(pattern: #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#)
    private static let angleId = try! NSRegularExpression(pattern: "<([^>]+)>")

    /// RFC 2047 encoded-word decoding.
    static func decodeHeader(_ value: String) -> String {
        guard value.has("=?") else { return value }
        let re = encodedWord
        let ns = value as NSString
        var out = ""
        var last = 0
        var lastWasWord = false
        for m in re.matches(in: value, range: NSRange(location: 0, length: ns.length)) {
            let between = ns.substring(with: NSRange(location: last, length: m.range.location - last))
            if !(lastWasWord && between.trimmingCharacters(in: .whitespaces).isEmpty) { out += between }
            let charset = ns.substring(with: m.range(at: 1)).split(separator: "*").first.map(String.init) ?? "utf-8"
            let enc = ns.substring(with: m.range(at: 2)).uppercased()
            let text = ns.substring(with: m.range(at: 3))
            let data: Data
            if enc == "B" {
                var b = text; while b.count % 4 != 0 { b += "=" }
                data = Data(base64Encoded: b) ?? Data()
            } else {
                data = quotedPrintable(Data(text.replacingOccurrences(of: "_", with: " ").utf8), header: true)
            }
            out += decodeCharset(data, charset: charset)
            last = m.range.location + m.range.length
            lastWasWord = true
        }
        out += ns.substring(from: last)
        return out
    }

    static func encodeHeaderWord(_ s: String) -> String {
        if s.allSatisfy({ $0.isASCII }) { return s }
        return "=?UTF-8?B?\(Data(s.utf8).base64EncodedString())?="
    }

    static func quotedPrintable(_ data: Data, header: Bool = false) -> Data {
        let b = [UInt8](data)
        var out = [UInt8](); out.reserveCapacity(b.count)
        var i = 0
        func hex(_ c: UInt8) -> UInt8? {
            switch c { case 48...57: return c - 48; case 65...70: return c - 55; case 97...102: return c - 87; default: return nil }
        }
        while i < b.count {
            let c = b[i]
            if c == 61 { // =
                if i + 1 < b.count, b[i + 1] == 13 || b[i + 1] == 10 {
                    i += 1
                    if i < b.count, b[i] == 13 { i += 1 }
                    if i < b.count, b[i] == 10 { i += 1 }
                    continue
                }
                if i + 2 < b.count, let h = hex(b[i + 1]), let l = hex(b[i + 2]) { out.append(h << 4 | l); i += 3; continue }
            }
            out.append(c); i += 1
        }
        return Data(out)
    }

    static func decodeTransfer(_ data: Data, _ cte: String) -> Data {
        switch cte.lowercased().trimmingCharacters(in: .whitespaces) {
        case "base64":
            let cleaned = data.filter { !($0 == 13 || $0 == 10 || $0 == 32 || $0 == 9) }
            var s = String(decoding: cleaned, as: UTF8.self)
            while s.count % 4 != 0 { s += "=" }
            return Data(base64Encoded: s, options: .ignoreUnknownCharacters) ?? data
        case "quoted-printable": return quotedPrintable(data)
        default: return data
        }
    }

    // MARK: addresses / ids / dates

    static func parseAddressList(_ raw: String) -> [EmailAddress] {
        let value = raw
        var items: [String] = []
        var cur = ""; var inQ = false; var depth = 0
        for ch in value {
            if ch == "\"" { inQ.toggle() }
            if !inQ { if ch == "<" { depth += 1 } else if ch == ">" { depth -= 1 } }
            if (ch == "," || ch == ";") && !inQ && depth == 0 { items.append(cur); cur = ""; continue }
            cur.append(ch)
        }
        items.append(cur)
        return items.compactMap { item in
            let t = item.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            if let lt = t.lastIndex(of: "<"), let gt = t.lastIndex(of: ">"), lt < gt {
                var name = t[..<lt].trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("\"") && name.hasSuffix("\"") && name.count >= 2 { name = String(name.dropFirst().dropLast()) }
                name = name.replacingOccurrences(of: "\\\"", with: "\"")
                let email = t[t.index(after: lt)..<gt].trimmingCharacters(in: .whitespaces)
                return EmailAddress(name: decodeHeader(name), email: email)
            }
            guard t.contains("@") else { return nil }
            return EmailAddress(name: "", email: t.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")))
        }
    }

    static func cleanId(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
    }

    static func idList(_ s: String) -> [String] {
        guard s.contains("<") else { return [] }
        let ns = s as NSString
        return angleId.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    private static let dateFormatters: [DateFormatter] = {
        ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz"].map {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = $0; return f
        }
    }()

    private static let months: [String: Int] = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
    private static let zones: [String: Int] = ["ut": 0, "utc": 0, "gmt": 0, "z": 0, "est": -300, "edt": -240, "cst": -360, "cdt": -300, "mst": -420, "mdt": -360, "pst": -480, "pdt": -420,
                                               "cet": 60, "cest": 120, "bst": 60, "ist": 330, "jst": 540, "aest": 600]

    /// Fast path for RFC 2822 dates ("[Tue,] 3 Jun 2025 10:22[:01] +0200"); DateFormatter was ~60 µs per call.
    static func fastParseDate(_ s: String) -> Date? {
        var toks: [Substring] = []
        for t in s.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" }) {
            if t.hasPrefix("(") { break }
            toks.append(t)
        }
        if let f = toks.first, f.count >= 3, Int(f) == nil, months[f.prefix(3).lowercased()] == nil { toks.removeFirst() } // weekday
        guard toks.count >= 4, let day = Int(toks[0]), let mon = months[toks[1].prefix(3).lowercased()], var year = Int(toks[2]) else { return nil }
        if year < 100 { year += year < 50 ? 2000 : 1900 }
        let hms = toks[3].split(separator: ":")
        guard hms.count >= 2, let hh = Int(hms[0]), let mm = Int(hms[1]) else { return nil }
        let ss = hms.count > 2 ? Int(hms[2].prefix(2)) ?? 0 : 0
        var offsetMin = 0
        if toks.count >= 5 {
            let z = toks[4]
            if let sign = z.first, sign == "+" || sign == "-", z.count >= 5, let v = Int(z.dropFirst().prefix(4)) {
                offsetMin = (v / 100 * 60 + v % 100) * (sign == "-" ? -1 : 1)
            } else if let v = zones[z.lowercased()] { offsetMin = v }
        }
        // Sender-controlled: a huge year would overflow the arithmetic below and crash.
        guard (1...31).contains(day), (0...23).contains(hh), (0...59).contains(mm), (0...60).contains(ss),
              (1000...9999).contains(year), abs(offsetMin) <= 24 * 60 else { return nil }
        // Days from civil (Howard Hinnant's algorithm), proleptic Gregorian, UTC.
        let y = mon <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (mon + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468
        let secs = days * 86400 + hh * 3600 + mm * 60 + ss - offsetMin * 60
        return Date(timeIntervalSince1970: TimeInterval(secs))
    }

    static func parseDate(_ s: String) -> Date? {
        if let d = fastParseDate(s) { return d }
        var t = s.trimmingCharacters(in: .whitespaces)
        if let p = t.firstIndex(of: "(") { t = t[..<p].trimmingCharacters(in: .whitespaces) }
        t = t.replacingOccurrences(of: "  ", with: " ")
        for f in dateFormatters { if let d = f.date(from: t) { return d } }
        return nil
    }

    static func rfc2822(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return f.string(from: d)
    }

    // MARK: full parse

    static func parse(_ data: Data) -> ParsedMessage {
        var msg = ParsedMessage()
        let (h, b) = splitHeaderBody(data)
        msg.headers = parseHeaders(h)
        var budget = 0
        walk(headers: msg.headers, body: b, into: &msg, depth: 0, parts: &budget)
        return msg
    }

    /// Limits shared by every level, including emails attached inside emails, so a crafted
    /// message can't nest deeply enough to exhaust the stack or keep the parser busy.
    static let maxDepth = 20, maxParts = 1000

    private static func walk(headers: [(String, String)], body: Data, into msg: inout ParsedMessage, depth: Int, parts: inout Int) {
        guard depth < maxDepth, parts < maxParts else { return }
        parts += 1
        func hv(_ n: String) -> String { headers.first { $0.0.caseInsensitiveCompare(n) == .orderedSame }?.1 ?? "" }
        let (ctype, params) = parseParams(hv("Content-Type").isEmpty ? "text/plain; charset=us-ascii" : hv("Content-Type"))
        let (disp, dparams) = parseParams(hv("Content-Disposition"))
        let cte = hv("Content-Transfer-Encoding")

        if ctype.hasPrefix("multipart/"), let boundary = params["boundary"] {
            for part in splitMultipart(body, boundary: boundary) {
                let (ph, pb) = splitHeaderBody(part)
                walk(headers: parseHeaders(ph), body: pb, into: &msg, depth: depth + 1, parts: &parts)
                if parts >= maxParts { break }
            }
            return
        }
        if ctype == "message/rfc822" && disp != "attachment" {
            let (ih, ib) = splitHeaderBody(decodeTransfer(body, cte))
            var inner = ParsedMessage()
            inner.headers = parseHeaders(ih)
            walk(headers: inner.headers, body: ib, into: &inner, depth: depth + 1, parts: &parts)
            if msg.text.isEmpty { msg.text = inner.text }
            msg.attachments += inner.attachments
            return
        }
        let decoded = decodeTransfer(body, cte)
        let filename = decodeHeader(dparams["filename"] ?? params["name"] ?? "")
        let isAttachment = disp == "attachment" || (!filename.isEmpty && !ctype.hasPrefix("text/"))
        if ctype == "text/calendar" || ctype == "application/ics" {
            msg.calendar = decodeCharset(decoded, charset: params["charset"] ?? "utf-8")
            if disp != "attachment" { return }
        }
        if !isAttachment && ctype == "text/plain" {
            let s = decodeCharset(decoded, charset: params["charset"] ?? "utf-8")
            msg.text += (msg.text.isEmpty ? "" : "\n\n") + s
        } else if !isAttachment && ctype == "text/html" {
            msg.html += decodeCharset(decoded, charset: params["charset"] ?? "utf-8")
        } else {
            let cid = cleanId(hv("Content-ID"))
            msg.attachments.append(MIMEPartAttachment(filename: filename.isEmpty ? "attachment" : filename, mimeType: ctype, data: decoded,
                                                      contentId: cid.isEmpty ? nil : cid, inline: disp == "inline" || (disp.isEmpty && !cid.isEmpty)))
        }
    }

    private static func splitMultipart(_ body: Data, boundary: String) -> [Data] {
        let delim = Data("--\(boundary)".utf8)
        var parts: [Data] = []
        var ranges: [Range<Data.Index>] = []
        var search = body.startIndex..<body.endIndex
        while let r = body.range(of: delim, in: search) {
            // must be at line start
            if r.lowerBound == body.startIndex || body[r.lowerBound - 1] == 10 { ranges.append(r) }
            search = r.upperBound..<body.endIndex
        }
        for (i, r) in ranges.enumerated() {
            var start = r.upperBound
            if start + 1 < body.endIndex, body[start] == 45, body[start + 1] == 45 { break } // closing --
            while start < body.endIndex, body[start] == 32 || body[start] == 9 { start += 1 }
            if start < body.endIndex, body[start] == 13 { start += 1 }
            if start < body.endIndex, body[start] == 10 { start += 1 }
            var end = i + 1 < ranges.count ? ranges[i + 1].lowerBound : body.endIndex
            if end > start, body[end - 1] == 10 { end -= 1 }
            if end > start, body[end - 1] == 13 { end -= 1 }
            if end > start { parts.append(body.subdata(in: start..<end)) }
        }
        return parts
    }

    // MARK: building

    struct OutgoingAttachment { var filename: String; var mimeType: String; var data: Data }

    static func build(from: EmailAddress, to: [EmailAddress], cc: [EmailAddress], replyTo: String?, subject: String,
                      text: String, html: String, inReplyTo: String?, references: [String], attachments: [OutgoingAttachment],
                      extraHeaders: [(String, String)] = [], messageId: String? = nil, date: Date = Date()) -> (Data, String) {
        let domain = from.domain.isEmpty ? "inkwell.local" : from.domain
        let mid = messageId ?? "\(UUID().uuidString)@\(domain)"
        var h: [(String, String)] = [
            ("Date", rfc2822(date)),
            ("From", from.formatted),
        ]
        if !to.isEmpty { h.append(("To", to.map(\.formatted).joined(separator: ", "))) }
        if !cc.isEmpty { h.append(("Cc", cc.map(\.formatted).joined(separator: ", "))) }
        if let replyTo, !replyTo.isEmpty { h.append(("Reply-To", replyTo)) }
        h.append(("Subject", encodeHeaderWord(subject)))
        h.append(("Message-ID", "<\(mid)>"))
        if let inReplyTo, !inReplyTo.isEmpty { h.append(("In-Reply-To", "<\(inReplyTo)>")) }
        if !references.isEmpty { h.append(("References", references.map { "<\($0)>" }.joined(separator: " "))) }
        h.append(("MIME-Version", "1.0"))
        h.append(("X-Mailer", "Inkwell"))
        h += extraHeaders

        let altBoundary = "alt-\(UUID().uuidString)"
        var alt = "Content-Type: multipart/alternative; boundary=\"\(altBoundary)\"\r\n\r\n"
        alt += "--\(altBoundary)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n\(wrap64(Data(text.utf8)))\r\n"
        alt += "--\(altBoundary)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n\(wrap64(Data(html.utf8)))\r\n"
        alt += "--\(altBoundary)--\r\n"

        // Values can come from incoming mail (a decoded subject or name may hold CR/LF); never
        // let one start a new header line.
        var out = h.map { "\(headerSafe($0.0)): \(headerSafe($0.1))" }.joined(separator: "\r\n") + "\r\n"
        if attachments.isEmpty {
            out += alt
        } else {
            let mixed = "mix-\(UUID().uuidString)"
            out += "Content-Type: multipart/mixed; boundary=\"\(mixed)\"\r\n\r\n"
            out += "--\(mixed)\r\n" + alt
            for a in attachments {
                let fn = headerSafe(SafeFile.basename(a.filename)).replacingOccurrences(of: "\"", with: "")
                let encName = fn.allSatisfy({ $0.isASCII }) ? "filename=\"\(fn)\"" : "filename*=UTF-8''\(fn.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "file")"
                out += "--\(mixed)\r\nContent-Type: \(headerSafe(a.mimeType)); name=\"\(encodeHeaderWord(fn))\"\r\nContent-Disposition: attachment; \(encName)\r\nContent-Transfer-Encoding: base64\r\n\r\n\(wrap64(a.data))\r\n"
            }
            out += "--\(mixed)--\r\n"
        }
        return (Data(out.utf8), mid)
    }

    /// Replaces CR, LF, NUL and other control characters with spaces.
    static func headerSafe(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return s }
        return String(String.UnicodeScalarView(s.unicodeScalars.map { $0.properties.generalCategory == .control && $0 != "\t" ? " " : $0 }))
    }

    static func wrap64(_ d: Data) -> String { d.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]) }

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdf": return "application/pdf"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        case "txt": return "text/plain"
        case "html", "htm": return "text/html"
        case "zip": return "application/zip"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "csv": return "text/csv"
        case "ics": return "text/calendar"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mp3": return "audio/mpeg"
        default: return "application/octet-stream"
        }
    }
}

enum HTMLText {
    private static func re(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: o) }
    private static let numericEntity = re("&#(x?)([0-9a-fA-F]+);")
    private static let urls = re("(https?://[^\\s<]+)")
    private static let onWrote = re("^On .+wrote:$")

    private static func sub(_ r: NSRegularExpression, _ s: String, _ t: String) -> String {
        r.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: t)
    }

    /// HTML → readable text in one pass over the UTF-8 bytes (regex version was ~4 ms per newsletter).
    static func toPlain(_ html: String) -> String {
        let b = Array(html.utf8)
        let n = b.count
        var out = [UInt8](); out.reserveCapacity(n / 3)
        @inline(__always) func lower(_ c: UInt8) -> UInt8 { c >= 65 && c <= 90 ? c + 32 : c }
        func find(_ needle: [UInt8], from: Int) -> Int? {
            guard !needle.isEmpty, from < n else { return nil }
            var i = from
            while i + needle.count <= n {
                if lower(b[i]) == needle[0] {
                    var k = 1
                    while k < needle.count && lower(b[i + k]) == needle[k] { k += 1 }
                    if k == needle.count { return i }
                }
                i += 1
            }
            return nil
        }
        let skipBlocks: Set<[UInt8]> = [Array("style".utf8), Array("script".utf8), Array("head".utf8), Array("title".utf8)]
        let lineBreakClose: Set<[UInt8]> = Set(["p", "div", "tr", "li", "h1", "h2", "h3", "h4", "h5", "h6", "table"].map { Array($0.utf8) })
        var i = 0
        while i < n {
            let c = b[i]
            guard c == 60 else { out.append(c); i += 1; continue }  // '<'
            if i + 3 < n, b[i + 1] == 33, b[i + 2] == 45, b[i + 3] == 45 {  // <!-- comment -->
                i = (find(Array("-->".utf8), from: i + 4).map { $0 + 3 }) ?? n; continue
            }
            var j = i + 1
            let closing = j < n && b[j] == 47
            if closing { j += 1 }
            let nameStart = j
            while j < n, (b[j] >= 48 && b[j] <= 57) || (lower(b[j]) >= 97 && lower(b[j]) <= 122) { j += 1 }
            let name = b[nameStart..<j].map(lower)
            guard let gt = b[j..<n].firstIndex(of: 62) else { break }  // '>'
            if !closing && skipBlocks.contains(name) {
                let endTag = Array("</".utf8) + name
                if let e = find(endTag, from: gt + 1), let close = b[e..<n].firstIndex(of: 62) { i = close + 1 } else { i = n }
                out.append(32); continue
            }
            out.append((name == Array("br".utf8) || (closing && lineBreakClose.contains(name))) ? 10 : 32)
            i = gt + 1
        }
        let text = decodeEntities(String(decoding: out, as: UTF8.self))
        // Collapse runs of spaces, trim lines, keep at most one blank line.
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var blank = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var collapsed = ""
            var space = false
            for ch in line {
                if ch == " " || ch == "\t" || ch == "\u{00A0}" || ch == "\r" { space = true; continue }
                if space && !collapsed.isEmpty { collapsed.append(" ") }
                space = false
                collapsed.append(ch)
            }
            if collapsed.isEmpty { blank += 1; continue }
            if !result.isEmpty { result += blank > 0 ? "\n\n" : "\n" }
            result += collapsed
            blank = 0
        }
        return result
    }

    private static let entityMap: [(String, String)] = [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&zwnj;", ""), ("&#8203;", ""), ("&rsquo;", "’"), ("&lsquo;", "‘"), ("&ldquo;", "“"), ("&rdquo;", "”"), ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"), ("&copy;", "©"), ("&amp;", "&")]

    static func decodeEntities(_ s: String) -> String {
        guard s.has("&") else { return s }
        var out = s
        for (k, v) in entityMap where out.has(k) { out = out.replacingOccurrences(of: k, with: v) }
        guard out.has("&#") else { return out }
        let ns = out as NSString
        var result = ""
        var last = 0
        for m in numericEntity.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let isHex = ns.substring(with: m.range(at: 1)) == "x"
            let num = ns.substring(with: m.range(at: 2))
            if let v = UInt32(num, radix: isHex ? 16 : 10), let sc = Unicode.Scalar(v) { result.append(Character(sc)) }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func fromPlain(_ s: String) -> String {
        let e = sub(urls, escape(s), "<a href=\"$1\">$1</a>")
        return "<div style=\"white-space: pre-wrap; word-wrap: break-word;\">\(e)</div>"
    }

    private static let mdImage = re("!\\[[^\\]]*\\]\\([^)]*\\)")
    private static let mdLink = re("\\[([^\\]]*)\\]\\((?:https?|mailto):[^)]*\\)")
    private static let imageMarker = re("\\[(?:image|img|cid)[^\\]]*\\]", .caseInsensitive)
    private static let angleURL = re("<(?:https?|mailto):[^>]*>")
    private static let bareURL = re("(?:https?://|www\\.)\\S+")
    private static let cssBlock = re("\\S*\\s*\\{[^{}]*:[^{}]*\\}")
    private static let dividers = re("[-=_*~|•]{3,}|\\*\\*|__")
    private static let ws = re("\\s+")

    /// Short readable preview for the message list: no quoted history, CSS, image markers,
    /// markdown link syntax or raw tracking URLs.
    static func snippet(_ p: ParsedMessage, limit: Int = 220) -> String {
        var source = p.text
        let head = String(source.prefix(400))
        let looksLikeCSS = head.has("{") && head.has(":") && head.has(";")
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (looksLikeCSS && !p.html.isEmpty) { source = toPlain(p.html) }
        var s = stripQuoted(String(source.prefix(6000)))
        if s.isEmpty { s = String(source.prefix(6000)) }
        s = sub(mdImage, s, " ")
        s = sub(mdLink, s, "$1")
        s = sub(imageMarker, s, " ")
        s = sub(angleURL, s, " ")
        s = sub(bareURL, s, " ")
        if s.has("{") { s = sub(cssBlock, s, " ") }
        s = sub(dividers, s, " ")
        s = sub(ws, s, " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(s.prefix(limit))
    }

    /// Strips quoted history from a plain text reply (for chat bubbles).
    static func stripQuoted(_ s: String) -> String {
        var lines: [Substring] = []
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(">") { break }
            if t.hasPrefix("On "), t.hasSuffix("wrote:"), onWrote.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) != nil { break }
            if t.hasPrefix("-----Original Message-----") || t.hasPrefix("From: ") && lines.count > 2 { break }
            if t == "--" || t == "-- " { break }
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
