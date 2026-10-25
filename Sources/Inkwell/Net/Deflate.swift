import Foundation
import zlib

/// IMAP COMPRESS=DEFLATE (RFC 4978): raw deflate in both directions, flushed after every
/// write so each command and response goes out whole. Mail text shrinks several times over,
/// which matters on slow links when syncing or downloading bodies.
final class DeflateStream {
    private var inf = z_stream()
    private var def = z_stream()
    private var buf = [UInt8](repeating: 0, count: 256 * 1024)

    init?() {
        let size = Int32(MemoryLayout<z_stream>.size)
        guard inflateInit2_(&inf, -15, ZLIB_VERSION, size) == Z_OK else { return nil }
        guard deflateInit2_(&def, 6, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, size) == Z_OK else {
            inflateEnd(&inf); return nil
        }
    }

    deinit { inflateEnd(&inf); deflateEnd(&def) }

    /// Inflates what arrived from the server; may return nothing if a block isn't complete yet.
    func decompress(_ input: UnsafeBufferPointer<UInt8>) throws -> Data {
        guard let base = input.baseAddress, !input.isEmpty else { return Data() }
        var out = Data()
        inf.next_in = UnsafeMutablePointer(mutating: base)
        inf.avail_in = UInt32(input.count)
        while true {
            let (rc, produced) = buf.withUnsafeMutableBufferPointer { p -> (Int32, Int) in
                inf.next_out = p.baseAddress; inf.avail_out = UInt32(p.count)
                let rc = inflate(&inf, Z_SYNC_FLUSH)
                return (rc, p.count - Int(inf.avail_out))
            }
            guard rc == Z_OK || rc == Z_BUF_ERROR || rc == Z_STREAM_END else {
                throw MailError.connection("compressed stream is corrupt")
            }
            out.append(contentsOf: buf[0..<produced])
            // Done once all input is consumed and the output buffer wasn't filled to the brim.
            if rc != Z_OK || (inf.avail_in == 0 && produced < buf.count) { break }
        }
        return out
    }

    func decompress(_ data: Data) throws -> Data {
        try data.withUnsafeBytes { try decompress($0.bindMemory(to: UInt8.self)) }
    }

    func compress(_ data: Data) -> Data {
        var out = Data()
        data.withUnsafeBytes { raw in
            def.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: UInt8.self).baseAddress)
            def.avail_in = UInt32(raw.count)
            while true {
                let produced = buf.withUnsafeMutableBufferPointer { p -> Int in
                    def.next_out = p.baseAddress; def.avail_out = UInt32(p.count)
                    _ = deflate(&def, Z_SYNC_FLUSH)
                    return p.count - Int(def.avail_out)
                }
                out.append(contentsOf: buf[0..<produced])
                if def.avail_out != 0 { break }
            }
        }
        return out
    }
}
