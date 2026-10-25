import Foundation

enum MailError: LocalizedError {
    case connection(String)
    case protocolError(String)
    case auth(String)
    case closed
    var errorDescription: String? {
        switch self {
        case .connection(let s): return "Connection failed: \(s)"
        case .protocolError(let s): return s
        case .auth(let s): return "Sign-in failed: \(s)"
        case .closed: return "Connection closed"
        }
    }
}

/// Blocking line-oriented TCP socket on top of CFStream so we get both implicit TLS and
/// in-place STARTTLS upgrades. Always used from a dedicated background queue/thread.
final class MailSocket {
    private let input: InputStream
    private let output: OutputStream
    private lazy var reader = LineReader { [unowned self] in try self.readChunk() }
    private let host: String
    private(set) var isOpen = false
    private var nativeHandle: Int32 = -1
    var log = false

    init(host: String, port: Int, tls: Bool, timeout: TimeInterval = 30) throws {
        self.host = host
        var r: InputStream?; var w: OutputStream?
        Stream.getStreamsToHost(withName: host, port: port, inputStream: &r, outputStream: &w)
        guard let r, let w else { throw MailError.connection("could not create stream to \(host)") }
        input = r; output = w
        if tls { enableTLS() }
        input.open(); output.open()
        let deadline = Date().addingTimeInterval(timeout)
        while input.streamStatus == .opening || output.streamStatus == .opening {
            if Date() > deadline { close(); throw MailError.connection("timed out connecting to \(host)") }
            Thread.sleep(forTimeInterval: 0.002)
        }
        if let e = input.streamError ?? output.streamError { throw MailError.connection(e.localizedDescription) }
        isOpen = true
        enableKeepAlive()
    }

    /// Without keepalive a connection silently dropped by sleep, Wi-Fi changes or a NAT timeout
    /// leaves a blocking read waiting forever, which stalls IDLE and every later sync.
    private func enableKeepAlive() {
        let key = Stream.PropertyKey(rawValue: CFStreamPropertyKey.socketNativeHandle.rawValue as String)
        guard let d = input.property(forKey: key) as? Data, d.count >= MemoryLayout<CFSocketNativeHandle>.size else { return }
        let fd = d.withUnsafeBytes { $0.loadUnaligned(as: CFSocketNativeHandle.self) }
        nativeHandle = fd
        func set(_ level: Int32, _ name: Int32, _ value: Int32) {
            var v = value
            setsockopt(fd, level, name, &v, socklen_t(MemoryLayout<Int32>.size))
        }
        set(SOL_SOCKET, SO_KEEPALIVE, 1)
        set(IPPROTO_TCP, TCP_KEEPALIVE, 60)
        set(IPPROTO_TCP, TCP_KEEPINTVL, 15)
        set(IPPROTO_TCP, TCP_KEEPCNT, 4)
    }

    /// Safe to call from any thread: wakes a read blocked on another thread (it fails with
    /// `.closed`) so the owner can reconnect.
    func abort() {
        isOpen = false
        if nativeHandle >= 0 { shutdown(nativeHandle, SHUT_RDWR) }
    }

    private func enableTLS() {
        let settings: [String: Any] = [kCFStreamSSLPeerName as String: host]
        let key = Stream.PropertyKey(kCFStreamPropertySSLSettings as String)
        input.setProperty(settings, forKey: key)
        output.setProperty(settings, forKey: key)
    }

    func startTLS() { enableTLS() }

    func close() {
        isOpen = false
        input.close(); output.close()
    }

    /// Total bytes received by all sockets (diagnostics / benchmarks).
    nonisolated(unsafe) static var bytesRead = 0

    private var chunk = [UInt8](repeating: 0, count: 65536)

    /// Set once the server accepted COMPRESS DEFLATE; everything after is deflated both ways.
    private var deflate: DeflateStream?
    var isCompressed: Bool { deflate != nil }

    /// Call right after the tagged OK to COMPRESS DEFLATE.
    func startCompression() throws {
        guard deflate == nil, let z = DeflateStream() else { return }
        deflate = z
        // Anything already buffered past the OK line is compressed data.
        try reader.transformUnread { try z.decompress($0) }
    }

    private func readChunk() throws -> Data {
        while true {
            let n = input.read(&chunk, maxLength: chunk.count)
            if n > 0 { MailSocket.bytesRead += n }
            if n < 0 { isOpen = false; throw MailError.connection(input.streamError?.localizedDescription ?? "read error") }
            if n == 0 { isOpen = false; throw MailError.closed }
            guard let z = deflate else { return Data(chunk[0..<n]) }
            let d = try chunk.withUnsafeBufferPointer { try z.decompress(UnsafeBufferPointer(rebasing: $0[0..<n])) }
            if !d.isEmpty { return d }
        }
    }

    /// Reads up to and including CRLF; returns the line without the terminator.
    func readLine() throws -> Data {
        let line = try reader.readLine()
        if log { NSLog("S: %@", String(decoding: line.prefix(300), as: UTF8.self)) }
        return line
    }

    func readLineString() throws -> String { String(decoding: try readLine(), as: UTF8.self) }

    func readBytes(_ count: Int) throws -> Data { try reader.readBytes(count) }

    func write(_ plain: Data) throws {
        let data = deflate?.compress(plain) ?? plain
        var offset = 0
        try data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            guard let base = p.bindMemory(to: UInt8.self).baseAddress else { return }
            while offset < data.count {
                let n = output.write(base + offset, maxLength: data.count - offset)
                if n <= 0 { isOpen = false; throw MailError.connection(output.streamError?.localizedDescription ?? "write error") }
                offset += n
            }
        }
    }

    func write(_ s: String) throws {
        if log { NSLog("C: %@", s.hasPrefix("A") && s.contains("LOGIN") ? "LOGIN ***" : String(s.prefix(300))) }
        try write(Data(s.utf8))
    }
}

/// Buffers bytes from a source and splits CRLF-terminated lines / fixed-size literals.
/// Consumed bytes are skipped with a read offset rather than removed from the front of the
/// buffer, which used to copy the rest of the buffer for every line.
final class LineReader {
    private var buffer = Data()
    private var head = 0          // offset of the first unread byte in `buffer`
    private var scanned = 0       // bytes after `head` already searched for CRLF
    private let source: () throws -> Data
    init(source: @escaping () throws -> Data) { self.source = source }

    private func fill() throws {
        if head > 0 && head >= buffer.count / 2 {
            buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + head)
            head = 0
        }
        buffer.append(try source())
    }

    func readLine() throws -> Data {
        while true {
            let base = buffer.startIndex + head
            // Resume the search one byte back in case CR ended the previous chunk.
            let from = base + max(0, scanned - 1)
            if let r = buffer[from..<buffer.endIndex].firstRange(of: crlf) {
                let line = buffer.subdata(in: base..<r.lowerBound)
                head = r.upperBound - buffer.startIndex
                scanned = 0
                return line
            }
            scanned = buffer.count - head
            try fill()
        }
    }

    func readBytes(_ count: Int) throws -> Data {
        while buffer.count - head < count { try fill() }
        let base = buffer.startIndex + head
        let d = buffer.subdata(in: base..<base + count)
        head += count
        scanned = 0
        return d
    }

    /// Replaces the bytes not yet consumed (used when the stream switches to compression).
    func transformUnread(_ f: (Data) throws -> Data) throws {
        let rest = buffer.subdata(in: buffer.startIndex + head..<buffer.endIndex)
        buffer = rest.isEmpty ? Data() : try f(rest)
        head = 0; scanned = 0
    }

    private let crlf = Data([13, 10])
}
