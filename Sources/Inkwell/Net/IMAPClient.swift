import Foundation

indirect enum IMAPValue: CustomStringConvertible {
    case atom(String)
    case string(Data)
    case list([IMAPValue])
    case nilValue

    var text: String? {
        switch self {
        case .atom(let s): return s
        case .string(let d): return String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self)
        case .nilValue: return nil
        case .list: return nil
        }
    }
    var data: Data? {
        switch self {
        case .string(let d): return d
        case .atom(let s): return Data(s.utf8)
        default: return nil
        }
    }
    var list: [IMAPValue]? { if case .list(let l) = self { return l }; return nil }
    var description: String {
        switch self {
        case .atom(let s): return s
        case .string(let d): return "\"\(String(decoding: d.prefix(80), as: UTF8.self))\""
        case .list(let l): return "(" + l.map(\.description).joined(separator: " ") + ")"
        case .nilValue: return "NIL"
        }
    }
}

enum IMAPParser {
    static func parse(_ data: Data) -> [IMAPValue] {
        let bytes = [UInt8](data)
        var i = 0
        return parseSeq(bytes, &i, until: nil)
    }

    private static func parseSeq(_ b: [UInt8], _ i: inout Int, until end: UInt8?) -> [IMAPValue] {
        var out: [IMAPValue] = []
        while i < b.count {
            let c = b[i]
            if c == 32 || c == 13 || c == 10 { i += 1; continue }
            if let end, c == end { i += 1; return out }
            if c == 40 { i += 1; out.append(.list(parseSeq(b, &i, until: 41))); continue }  // (
            if c == 41 { i += 1; continue }
            if c == 34 { out.append(.string(parseQuoted(b, &i))); continue }
            if c == 123, let lit = parseLiteral(b, &i) { out.append(.string(lit)); continue }  // {
            let atom = parseAtom(b, &i)
            out.append(atom.uppercased() == "NIL" ? .nilValue : .atom(atom))
        }
        return out
    }

    private static func parseQuoted(_ b: [UInt8], _ i: inout Int) -> Data {
        i += 1
        var out = [UInt8]()
        while i < b.count {
            let c = b[i]
            if c == 92, i + 1 < b.count { out.append(b[i + 1]); i += 2; continue }
            if c == 34 { i += 1; break }
            out.append(c); i += 1
        }
        return Data(out)
    }

    private static func parseLiteral(_ b: [UInt8], _ i: inout Int) -> Data? {
        var j = i + 1
        var n = 0
        var digits = false
        while j < b.count, b[j] >= 48 && b[j] <= 57 { n = n * 10 + Int(b[j] - 48); j += 1; digits = true }
        if j < b.count, b[j] == 43 { j += 1 }  // +
        guard digits, j < b.count, b[j] == 125 else { return nil }
        j += 1
        if j < b.count, b[j] == 13 { j += 1 }
        if j < b.count, b[j] == 10 { j += 1 }
        let endIdx = min(b.count, j + n)
        let d = Data(b[j..<endIdx])
        i = endIdx
        return d
    }

    private static func parseAtom(_ b: [UInt8], _ i: inout Int) -> String {
        var out = [UInt8]()
        var depth = 0
        while i < b.count {
            let c = b[i]
            if c == 91 { depth += 1 }       // [
            if c == 93 { depth -= 1 }       // ]
            if depth <= 0 && (c == 32 || c == 40 || c == 41 || c == 13 || c == 10) { break }
            out.append(c); i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }
}

struct FetchResult {
    var seq: Int = 0
    var uid: UInt32 = 0
    var flags: [String] = []
    var internalDate: Date?
    var size: Int = 0
    var header: Data?
    var body: Data?
    var gmThreadId: String?
}

struct SelectInfo {
    var exists = 0
    var uidValidity: UInt32 = 0
    var uidNext: UInt32 = 0
    var highestModSeq: UInt64 = 0
}

final class IMAPClient {
    private let socket: MailSocket
    private var tag = 0
    private(set) var capabilities = Set<String>()
    private(set) var selected: String?
    var isConnected: Bool { socket.isOpen }
    private let capsKey: String

    init(host: String, port: Int) throws {
        capsKey = "\(host):\(port)"
        // Plaintext only for local test servers, and only when explicitly enabled.
        let insecureLocal = host == "127.0.0.1" && ProcessInfo.processInfo.environment["INKWELL_INSECURE_LOCAL"] == "1"
        let implicit = port != 143 && !insecureLocal
        socket = try MailSocket(host: host, port: port, tls: implicit)
        let greeting = try socket.readLineString()
        guard greeting.hasPrefix("* OK") || greeting.hasPrefix("* PREAUTH") else { throw MailError.protocolError("Bad greeting: \(greeting)") }
        parseCaps(greeting)
        if !implicit && !insecureLocal {
            _ = try command("STARTTLS")
            socket.startTLS()
        }
    }

    deinit { socket.close() }

    func close() { socket.close() }

    /// Thread-safe: interrupts whatever this client is blocked on.
    func abort() { socket.abort() }

    // MARK: core

    private func nextTag() -> String { tag += 1; return "A\(tag)" }

    /// Reads one logical response (a line plus any literals it announces).
    func readResponse() throws -> Data {
        var out = try socket.readLine()
        while let n = literalLength(out) {
            out.append(contentsOf: [13, 10])
            out.append(try socket.readBytes(n))
            out.append(try socket.readLine())
        }
        return out
    }

    private func literalLength(_ line: Data) -> Int? {
        guard line.last == 125 else { return nil }  // }
        guard let open = line.lastIndex(of: 123) else { return nil }
        var s = String(decoding: line[(open + 1)..<(line.endIndex - 1)], as: UTF8.self)
        if s.hasSuffix("+") { s.removeLast() }
        return Int(s)
    }

    @discardableResult
    func command(_ cmd: String, literal: Data? = nil) throws -> [Data] {
        freshSelect = nil
        let t = nextTag()
        var untagged: [Data] = []
        if let literal {
            try socket.write("\(t) \(cmd) {\(literal.count)}\r\n")
            let cont = try readResponse()
            guard cont.first == 43 else { throw MailError.protocolError(String(decoding: cont, as: UTF8.self)) }
            try socket.write(literal)
            try socket.write("\r\n")
        } else {
            try socket.write("\(t) \(cmd)\r\n")
        }
        while true {
            let line = try readResponse()
            if line.starts(with: Data((t + " ").utf8)) {
                let rest = String(decoding: line.dropFirst(t.count + 1), as: UTF8.self)
                if rest.hasPrefix("OK") {
                    parseCaps(rest)
                    return untagged
                }
                if cmd.hasPrefix("LOGIN") || cmd.hasPrefix("AUTHENTICATE") { throw MailError.auth(rest) }
                throw MailError.protocolError("\(cmd.split(separator: " ").first ?? ""): \(rest)")
            }
            if line.first == 42 { untagged.append(line) }  // *
        }
    }

    /// Sends several commands in one write and reads all their responses: one network round
    /// trip instead of one per command. Returns each command's untagged lines, in order.
    func pipeline(_ cmds: [String]) throws -> [[Data]] {
        var out: [[Data]] = []
        try pipeline(cmds) { _, lines in out.append(lines) }
        return out
    }

    /// Streaming variant: `each` gets a command's untagged lines as soon as it completes, so
    /// big responses (body prefetch) are processed one at a time instead of all held in memory.
    func pipeline(_ cmds: [String], each: (Int, [Data]) throws -> Void) throws {
        guard !cmds.isEmpty else { return }
        freshSelect = nil
        let tags = cmds.map { _ in nextTag() }
        try socket.write(zip(tags, cmds).map { "\($0) \($1)\r\n" }.joined())
        var failure: Error?
        var lines: [Data] = []
        var i = 0
        while i < cmds.count {
            let line = try readResponse()
            if line.starts(with: Data((tags[i] + " ").utf8)) {
                let rest = String(decoding: line.dropFirst(tags[i].count + 1), as: UTF8.self)
                if rest.hasPrefix("OK") {
                    parseCaps(rest)
                    // Keep reading the remaining responses even after an error, so the stream stays in sync.
                    if failure == nil { do { try each(i, lines) } catch { failure = error } }
                } else if failure == nil {
                    failure = MailError.protocolError("\(cmds[i].split(separator: " ").first ?? ""): \(rest)")
                }
                lines = []
                i += 1
            } else if line.first == 42 { lines.append(line) }
        }
        if let failure { throw failure }
    }

    private func parseCaps(_ s: String) {
        guard let r = s.range(of: "[CAPABILITY ") else { return }
        let tail = s[r.upperBound...]
        if let end = tail.firstIndex(of: "]") {
            capabilities = Set(tail[..<end].uppercased().split(separator: " ").map(String.init))
        }
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: commands

    /// Signs in. With `select`, the first SELECT goes out in the same write as LOGIN (built from
    /// the capabilities this server announced last time), saving a round trip on every connect.
    /// `compress`: also turn on COMPRESS=DEFLATE, as the last command of that same write (after
    /// it everything is deflated, so nothing may follow it uncompressed). Costs no round trip.
    func login(user: String, password: String, select folder: String? = nil, readOnly: Bool = false, compress: Bool = false) throws {
        let loginCmd = "LOGIN \(IMAPClient.quote(user)) \(IMAPClient.quote(password))"
        var sentSelect: String?
        if let folder, let known = IMAPClient.knownCaps(capsKey) {
            let real = capabilities
            capabilities = known
            sentSelect = selectCommand(folder, readOnly: readOnly)
            capabilities = real
            let deflate = compress && known.contains("COMPRESS=DEFLATE") && IMAPClient.compressionAllowed
            let r = try pipelineStatus([loginCmd, sentSelect!] + (deflate ? ["COMPRESS DEFLATE"] : []))
            if case .failure(let e) = r[0] { throw e }
            if case .success(let lines) = r[1] { didSelect(folder, IMAPClient.parseSelect(lines), readOnly: readOnly) }
            if deflate, case .success = r[2] { try socket.startCompression() }
        } else {
            try command(loginCmd)
        }
        if capabilities.isEmpty || !capabilities.contains("IMAP4REV1") {
            for line in try command("CAPABILITY") {
                let s = String(decoding: line, as: UTF8.self)
                if s.hasPrefix("* CAPABILITY ") {
                    capabilities = Set(s.dropFirst(13).uppercased().split(separator: " ").map(String.init))
                }
            }
        }
        IMAPClient.rememberCaps(capabilities, capsKey)
        // First connection to this server (nothing cached to pipeline with): one extra round
        // trip, worth it for the initial sync, which is the biggest download.
        if sentSelect == nil, compress, capabilities.contains("COMPRESS=DEFLATE"), IMAPClient.compressionAllowed {
            if (try? command("COMPRESS DEFLATE")) != nil { try socket.startCompression() }
        }
        // Only trust the early SELECT if it's the one we'd send now (same CONDSTORE choice).
        if let folder, let sentSelect, selected == folder, sentSelect == selectCommand(folder, readOnly: readOnly) {
            freshSelect = folder
        } else if sentSelect != nil {
            forgetSelection()
        }
    }

    var isCompressed: Bool { socket.isCompressed }
    /// `INKWELL_NO_COMPRESS=1` turns it off (benchmarks, debugging).
    static let compressionAllowed = ProcessInfo.processInfo.environment["INKWELL_NO_COMPRESS"] == nil

    /// Folder selected together with LOGIN, until any other command runs.
    private var freshSelect: String?

    /// The SELECT that rode along with LOGIN, if nothing has run since: use it instead of
    /// selecting again.
    func takeFreshSelect(_ folder: String, readOnly: Bool = false) -> SelectInfo? {
        defer { freshSelect = nil }
        guard freshSelect == folder, selectedReadOnly == readOnly else { return nil }
        return selectInfo
    }

    private static let capsLock = NSLock()
    nonisolated(unsafe) private static var capsCache: [String: Set<String>] = [:]

    private static func knownCaps(_ key: String) -> Set<String>? {
        capsLock.lock(); defer { capsLock.unlock() }
        if let c = capsCache[key] { return c }
        guard let list = UserDefaults.standard.stringArray(forKey: "imap.caps." + key), !list.isEmpty else { return nil }
        capsCache[key] = Set(list)
        return capsCache[key]
    }

    private static func rememberCaps(_ caps: Set<String>, _ key: String) {
        guard !caps.isEmpty else { return }
        capsLock.lock(); defer { capsLock.unlock() }
        guard capsCache[key] != caps else { return }
        capsCache[key] = caps
        UserDefaults.standard.set(caps.sorted(), forKey: "imap.caps." + key)
    }

    /// Pipelines commands and reports each one's outcome instead of throwing on the first `NO`.
    private func pipelineStatus(_ cmds: [String]) throws -> [Result<[Data], MailError>] {
        let tags = cmds.map { _ in nextTag() }
        try socket.write(zip(tags, cmds).map { "\($0) \($1)\r\n" }.joined())
        var out: [Result<[Data], MailError>] = []
        var lines: [Data] = []
        while out.count < cmds.count {
            let i = out.count
            let line = try readResponse()
            if line.starts(with: Data((tags[i] + " ").utf8)) {
                let rest = String(decoding: line.dropFirst(tags[i].count + 1), as: UTF8.self)
                if rest.hasPrefix("OK") { parseCaps(rest); out.append(.success(lines)) }
                else if cmds[i].hasPrefix("LOGIN") { out.append(.failure(.auth(rest))) }
                else { out.append(.failure(.protocolError("\(cmds[i].split(separator: " ").first ?? ""): \(rest)"))) }
                lines = []
            } else if line.first == 42 { lines.append(line) }
        }
        return out
    }

    func authenticateXOAUTH2(user: String, token: String) throws {
        let s = "user=\(user)\u{1}auth=Bearer \(token)\u{1}\u{1}"
        try command("AUTHENTICATE XOAUTH2 \(Data(s.utf8).base64EncodedString())")
    }

    func list() throws -> [(attrs: [String], delimiter: String, path: String)] {
        var out: [(attrs: [String], delimiter: String, path: String)] = []
        for line in try command("LIST \"\" \"*\"") {
            let v = IMAPParser.parse(line)
            guard v.count >= 5, v[1].text?.uppercased() == "LIST" else { continue }
            let attrs = v[2].list?.compactMap { $0.text } ?? []
            out.append((attrs, v[3].text ?? "/", v[4].text ?? ""))
        }
        return out
    }

    func selectCommand(_ folder: String, readOnly: Bool = false) -> String {
        "\(readOnly ? "EXAMINE" : "SELECT") \(IMAPClient.quote(folder))\(supportsCondstore ? " (CONDSTORE)" : "")"
    }

    @discardableResult
    func select(_ folder: String, readOnly: Bool = false) throws -> SelectInfo {
        forgetSelection()  // a failed SELECT leaves no mailbox selected
        let info = IMAPClient.parseSelect(try command(selectCommand(folder, readOnly: readOnly)))
        didSelect(folder, info, readOnly: readOnly)
        return info
    }

    /// Selects `folder` read-write unless it already is; saves a round trip per action.
    func ensureSelected(_ folder: String) throws {
        if selected == folder && !selectedReadOnly { return }
        try select(folder)
    }

    /// Like `ensureSelected`, for reads: an EXAMINE'd folder is fine too.
    func ensureReadable(_ folder: String) throws {
        if selected == folder { return }
        try select(folder)
    }

    /// What the latest SELECT reported, so a follow-up pass on the same folder can skip its own.
    private(set) var selectInfo: SelectInfo?

    /// Records a SELECT (also one sent through `pipeline`).
    func didSelect(_ folder: String, _ info: SelectInfo, readOnly: Bool = false) { selected = folder; selectInfo = info; selectedReadOnly = readOnly }
    private(set) var selectedReadOnly = false
    func forgetSelection() { selected = nil; selectInfo = nil }

    static func parseSelect(_ lines: [Data]) -> SelectInfo {
        var info = SelectInfo()
        for line in lines {
            let s = String(decoding: line, as: UTF8.self)
            let parts = s.split(separator: " ")
            if parts.count >= 3, parts[2].uppercased() == "EXISTS" { info.exists = Int(parts[1]) ?? 0 }
            if let r = s.range(of: "[UIDVALIDITY ") { info.uidValidity = UInt32(s[r.upperBound...].prefix { $0.isNumber }) ?? 0 }
            if let r = s.range(of: "[UIDNEXT ") { info.uidNext = UInt32(s[r.upperBound...].prefix { $0.isNumber }) ?? 0 }
            if let r = s.range(of: "[HIGHESTMODSEQ ") { info.highestModSeq = UInt64(s[r.upperBound...].prefix { $0.isNumber }) ?? 0 }
        }
        return info
    }

    func uidSearch(_ criteria: String) throws -> [UInt32] {
        IMAPClient.parseSearch(try command("UID SEARCH \(criteria)"))
    }

    static func parseSearch(_ lines: [Data]) -> [UInt32] {
        var out: [UInt32] = []
        for line in lines {
            let s = String(decoding: line, as: UTF8.self)
            if s.hasPrefix("* SEARCH") {
                out += s.dropFirst(8).split(separator: " ").compactMap { UInt32($0) }
            }
        }
        return out
    }

    var supportsCondstore: Bool { capabilities.contains("CONDSTORE") || capabilities.contains("QRESYNC") }

    static func fetchCommand(_ set: String, items: String, byUID: Bool = true, changedSince: UInt64? = nil) -> String {
        "\(byUID ? "UID " : "")FETCH \(set) (\(items))" + (changedSince.map { " (CHANGEDSINCE \($0))" } ?? "")
    }

    func fetch(_ set: String, items: String, byUID: Bool = true, changedSince: UInt64? = nil) throws -> [FetchResult] {
        IMAPClient.parseFetch(try command(IMAPClient.fetchCommand(set, items: items, byUID: byUID, changedSince: changedSince)))
    }

    static func parseFetch(_ lines: [Data]) -> [FetchResult] {
        var results: [FetchResult] = []
        for line in lines {
            let v = IMAPParser.parse(line)
            guard v.count >= 4, v[2].text?.uppercased() == "FETCH", let kv = v[3].list else { continue }
            var r = FetchResult()
            r.seq = Int(v[1].text ?? "") ?? 0
            var i = 0
            while i + 1 < kv.count {
                let key = (kv[i].text ?? "").uppercased()
                let val = kv[i + 1]
                switch key {
                case "UID": r.uid = UInt32(val.text ?? "") ?? 0
                case "FLAGS": r.flags = val.list?.compactMap { $0.text } ?? []
                case "INTERNALDATE": r.internalDate = val.text.flatMap(IMAPClient.parseInternalDate)
                case "RFC822.SIZE": r.size = Int(val.text ?? "") ?? 0
                case "X-GM-THRID": r.gmThreadId = val.text
                default:
                    if key.hasPrefix("BODY[HEADER") { r.header = val.data }
                    else if key.hasPrefix("BODY[]") || key == "RFC822" { r.body = val.data }
                }
                i += 2
            }
            if r.uid != 0 { results.append(r) }
        }
        return results
    }

    func store(_ set: String, flags: String, add: Bool) throws {
        try command("UID STORE \(set) \(add ? "+" : "-")FLAGS.SILENT (\(flags))")
    }

    func move(_ set: String, to dest: String) throws {
        if capabilities.contains("MOVE") {
            try command("UID MOVE \(set) \(IMAPClient.quote(dest))")
        } else {
            try command("UID COPY \(set) \(IMAPClient.quote(dest))")
            try store(set, flags: "\\Deleted", add: true)
            if capabilities.contains("UIDPLUS") { try command("UID EXPUNGE \(set)") } else { try command("EXPUNGE") }
        }
    }

    func expunge(_ set: String) throws {
        try store(set, flags: "\\Deleted", add: true)
        if capabilities.contains("UIDPLUS") { try command("UID EXPUNGE \(set)") } else { try command("EXPUNGE") }
    }

    func append(_ folder: String, flags: String, message: Data) throws {
        try command("APPEND \(IMAPClient.quote(folder)) (\(flags))", literal: message)
    }

    func create(_ folder: String) throws { try command("CREATE \(IMAPClient.quote(folder))") }

    func noop() throws { try command("NOOP") }

    /// Blocks in IDLE until the server reports a change or `stopper` is triggered.
    /// Returns true if the mailbox changed.
    /// `onChange` runs as soon as the change is pushed (with the new message count for EXISTS), without waiting for the DONE round trip.
    func idle(maxDuration: TimeInterval, stopper: IdleStopper, onChange: ((_ exists: Int?) -> Void)? = nil) throws -> Bool {
        let t = nextTag()
        try socket.write("\(t) IDLE\r\n")
        let cont = try readResponse()
        guard cont.first == 43 else { throw MailError.protocolError("IDLE not supported") }
        var changed = false
        var doneSent = false
        var finished = false
        let lock = NSLock()
        let socket = self.socket
        let sendDone: () -> Void = {
            lock.lock(); defer { lock.unlock() }
            guard !doneSent, !finished else { return }
            doneSent = true
            try? socket.write("DONE\r\n")
            // A healthy server answers DONE immediately; silence means the connection is dead.
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
                lock.lock(); defer { lock.unlock() }
                if !finished { socket.abort() }
            }
        }
        stopper.handler = sendDone
        let timer = DispatchWorkItem(block: sendDone)
        DispatchQueue.global().asyncAfter(deadline: .now() + maxDuration, execute: timer)
        defer {
            timer.cancel(); stopper.handler = nil
            lock.lock(); finished = true; lock.unlock()
        }
        while true {
            let line = try readResponse()
            if line.starts(with: Data((t + " ").utf8)) { return changed }
            let s = String(decoding: line, as: UTF8.self).uppercased()
            if s.hasSuffix("EXISTS") || s.hasSuffix("EXPUNGE") || s.contains("FETCH") {
                if !changed { onChange?(s.hasSuffix("EXISTS") ? Int(s.split(separator: " ").dropFirst().first ?? "") : nil) }
                changed = true
                sendDone()
            }
        }
    }

    static func uidSet(_ uids: [UInt32]) -> String {
        let s = uids.sorted()
        guard var start = s.first else { return "0" }
        var prev = start
        var parts: [String] = []
        for u in s.dropFirst() {
            if u == prev + 1 { prev = u; continue }
            parts.append(start == prev ? "\(start)" : "\(start):\(prev)")
            start = u; prev = u
        }
        parts.append(start == prev ? "\(start)" : "\(start):\(prev)")
        return parts.joined(separator: ",")
    }

    static let internalDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        return f
    }()
    static func parseInternalDate(_ s: String) -> Date? {
        internalDateFormatter.date(from: s.trimmingCharacters(in: .whitespaces))
    }
}

final class IdleStopper {
    var handler: (() -> Void)?
    func stop() { handler?() }
}

/// RFC 3501 modified UTF-7 for folder names.
enum MUTF7 {
    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "&" {
                guard let end = s[i...].firstIndex(of: "-") else { out.append(contentsOf: s[i...]); break }
                let chunk = s[s.index(after: i)..<end]
                if chunk.isEmpty { out.append("&") } else {
                    var b64 = chunk.replacingOccurrences(of: ",", with: "/")
                    while b64.count % 4 != 0 { b64 += "=" }
                    if let d = Data(base64Encoded: b64), let str = String(data: d, encoding: .utf16BigEndian) { out += str }
                }
                i = s.index(after: end)
            } else { out.append(c); i = s.index(after: i) }
        }
        return out
    }

    static func encode(_ s: String) -> String {
        var out = ""
        var pending = ""
        func flush() {
            guard !pending.isEmpty else { return }
            let d = pending.data(using: .utf16BigEndian)!
            out += "&" + d.base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "/", with: ",") + "-"
            pending = ""
        }
        for ch in s {
            if ch.isASCII && ch != "&" { flush(); out.append(ch) }
            else if ch == "&" { flush(); out += "&-" }
            else { pending.append(ch) }
        }
        flush()
        return out
    }
}
