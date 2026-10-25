import Foundation

extension StringProtocol {
    /// Byte-level substring test (memmem). Swift's `contains(_: String)` goes through Foundation's
    /// generic grapheme-aware search and was the top hotspot when scanning mail bodies.
    @inline(__always)
    func has(_ needle: String) -> Bool {
        var hay = String(self)
        var n = needle
        return hay.withUTF8 { h in
            n.withUTF8 { nb in
                guard nb.count > 0 else { return true }
                guard h.count >= nb.count else { return false }
                return memmem(h.baseAddress, h.count, nb.baseAddress, nb.count) != nil
            }
        }
    }
}
