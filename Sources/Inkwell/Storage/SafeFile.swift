import Foundation

/// Attachment names come from the sender: treat them as labels, never as paths.
enum SafeFile {
    /// One harmless path component: no separators, controls or leading dots, never empty.
    static func basename(_ raw: String, fallback: String = "attachment") -> String {
        let bad = CharacterSet(charactersIn: "/\\:\u{0}").union(.controlCharacters).union(.newlines)
        var s = raw.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.isEmpty || s == "-" { s = fallback }
        if s.count > 180 {
            let ext = (s as NSString).pathExtension
            let stem = String((s as NSString).deletingPathExtension.prefix(ext.isEmpty || ext.count > 10 ? 180 : 168))
            s = ext.isEmpty || ext.count > 10 ? stem : stem + "." + ext
        }
        return s
    }

    /// Creates a new file in `dir` (never overwriting or following a symlink), adding " 2", " 3"…
    /// to the name until it's free. Returns where it was written.
    @discardableResult
    static func writeUnique(_ data: Data, named name: String, in dir: URL) throws -> URL {
        let base = basename(name)
        let ext = (base as NSString).pathExtension, stem = (base as NSString).deletingPathExtension
        let root = dir.standardizedFileURL.resolvingSymlinksInPath().path
        for n in 1...10_000 {
            let file = n == 1 ? base : (ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            let u = dir.appendingPathComponent(file, isDirectory: false)
            guard u.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path == root else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            let fd = open(u.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
            if fd < 0 {
                if errno == EEXIST { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try h.write(contentsOf: data)
            return u
        }
        throw CocoaError(.fileWriteFileExists)
    }
}
