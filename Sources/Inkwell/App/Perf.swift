import Foundation
import Darwin

/// `INKWELL_PERF=1`: prints milestones as milliseconds since the process was spawned.
enum Perf {
    static let enabled = ProcessInfo.processInfo.environment["INKWELL_PERF"] != nil

    /// Kernel spawn time of this process, so dyld/runtime start-up is included.
    private static let spawn: Double = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date().timeIntervalSince1970 }
        let t = info.kp_proc.p_un.__p_starttime
        return Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000
    }()

    private static var marked: Set<String> = []
    private static let lock = NSLock()

    /// Start of the conversation currently being opened (uptime ms).
    nonisolated(unsafe) static var openStart: Double = 0
    static func uptimeMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }
    /// Logs a step of opening a conversation, relative to `openStart`.
    static func open(_ label: @autoclosure () -> String) {
        guard enabled else { return }
        print(String(format: "[open] %7.1f ms  %@", uptimeMs() - openStart, label())); fflush(stdout)
    }

    /// Logs `label` the first time it is reached.
    static func mark(_ label: String) {
        guard enabled else { return }
        lock.lock(); let first = marked.insert(label).inserted; lock.unlock()
        guard first else { return }
        let ms = (Date().timeIntervalSince1970 - spawn) * 1000
        print(String(format: "[perf] %8.1f ms  %@", ms, label))
        fflush(stdout)
    }
}
