import Foundation

final class SMTPClient {
    private let socket: MailSocket
    private var extensions: [String] = []

    init(host: String, port: Int, security: SMTPSecurity) throws {
        socket = try MailSocket(host: host, port: port, tls: security == .ssl)
        _ = try expect(220)
        try ehlo()
        if security == .starttls {
            try send("STARTTLS", expect: 220)
            socket.startTLS()
            try ehlo()
        }
    }

    deinit { socket.close() }

    /// EHLO needs a valid hostname. The Mac's display name (e.g. "Jane’s-MacBook") contains
    /// characters servers like Gmail reject, so reduce it to letters/digits/hyphens, else use
    /// an address literal.
    static let heloName: String = {
        let raw = ProcessInfo.processInfo.hostName
        let cleaned = raw.lowercased().unicodeScalars.map { c -> Character in
            (("a"..."z").contains(c) || ("0"..."9").contains(c) || c == "." || c == "-") ? Character(c) : "-"
        }
        var name = String(cleaned).replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        if name.isEmpty || name == "localhost" { return "[127.0.0.1]" }
        if !name.contains(".") { name += ".local" }
        return name
    }()

    private func ehlo() throws {
        let lines = try send("EHLO \(SMTPClient.heloName)", expect: 250)
        extensions = lines.map { String($0.dropFirst(4)).uppercased() }
    }

    private func readReply() throws -> (Int, [String]) {
        var lines: [String] = []
        while true {
            let l = try socket.readLineString()
            lines.append(l)
            if l.count < 4 || l[l.index(l.startIndex, offsetBy: 3)] != "-" {
                return (Int(l.prefix(3)) ?? 0, lines)
            }
        }
    }

    @discardableResult
    private func expect(_ code: Int) throws -> [String] {
        let (c, lines) = try readReply()
        guard c == code || (code == 250 && c == 251) else { throw MailError.protocolError("SMTP \(c): \(lines.joined(separator: " "))") }
        return lines
    }

    @discardableResult
    private func send(_ cmd: String, expect code: Int) throws -> [String] {
        try socket.write(cmd + "\r\n")
        return try expect(code)
    }

    func login(user: String, password: String) throws {
        let auth = extensions.first { $0.hasPrefix("AUTH") } ?? "AUTH PLAIN LOGIN"
        do {
            if auth.contains("PLAIN") {
                let token = Data("\u{0}\(user)\u{0}\(password)".utf8).base64EncodedString()
                try send("AUTH PLAIN \(token)", expect: 235)
            } else {
                try send("AUTH LOGIN", expect: 334)
                try send(Data(user.utf8).base64EncodedString(), expect: 334)
                try send(Data(password.utf8).base64EncodedString(), expect: 235)
            }
        } catch {
            throw MailError.auth(error.localizedDescription)
        }
    }

    func sendMail(from: String, recipients: [String], data: Data) throws {
        // Envelope addresses go straight into SMTP commands: no spaces, brackets or line breaks.
        let bad = CharacterSet.whitespacesAndNewlines.union(.controlCharacters).union(CharacterSet(charactersIn: "<>"))
        for a in [from] + recipients where a.rangeOfCharacter(from: bad) != nil || !a.contains("@") {
            throw MailError.protocolError("Invalid email address: \(a.prefix(80))")
        }
        try send("MAIL FROM:<\(from)>", expect: 250)
        for r in recipients { try send("RCPT TO:<\(r)>", expect: 250) }
        try send("DATA", expect: 354)
        // Dot-stuffing + ensure CRLF line endings
        var text = String(decoding: data, as: UTF8.self)
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        if text.hasPrefix(".") { text = "." + text }
        text = text.replacingOccurrences(of: "\r\n.", with: "\r\n..")
        if !text.hasSuffix("\r\n") { text += "\r\n" }
        try socket.write(text + ".\r\n")
        try expect(250)
    }

    func quit() { try? socket.write("QUIT\r\n"); socket.close() }
}
