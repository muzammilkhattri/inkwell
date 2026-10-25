import Foundation

/// Writes a small JSON snapshot (unread counts + newest conversations) that a WidgetKit
/// extension or other tools can read. Also used by `Inkwell --status`.
enum WidgetBridge {
    struct Snapshot: Codable {
        struct AccountRow: Codable { var label: String; var color: String; var unread: Int }
        struct ThreadRow: Codable { var sender: String; var subject: String; var date: Date; var unread: Bool; var color: String }
        var totalUnread: Int
        var accounts: [AccountRow]
        var latest: [ThreadRow]
        var updated: Date
    }

    static var url: URL { Paths.appSupport.appendingPathComponent("widget.json") }
    @MainActor private static var lastWritten: Data?

    @MainActor
    static func publish(store: MailStore, inboxThreads: [ThreadSummary]) {
        let colors = Dictionary(store.accounts.map { ($0.id, $0.colorHex) }, uniquingKeysWith: { a, _ in a })
        let snap = Snapshot(
            totalUnread: store.unreadCounts.values.reduce(0, +),
            accounts: store.accounts.map { .init(label: $0.label, color: $0.colorHex, unread: store.unreadCounts[$0.id] ?? 0) },
            latest: inboxThreads.prefix(8).map { .init(sender: $0.latest.from.display, subject: $0.latest.subject, date: $0.latest.date, unread: $0.unread, color: colors[$0.accountId] ?? "#4F7CFF") },
            updated: Date(timeIntervalSince1970: 0))
        // Skip the disk write when nothing visible changed (reload runs after every action).
        guard let d = try? JSONEncoder().encode(snap), d != lastWritten else { return }
        lastWritten = d
        var stamped = snap; stamped.updated = Date()
        let out = (try? JSONEncoder().encode(stamped)) ?? d
        let target = url
        DispatchQueue.global(qos: .utility).async { try? out.write(to: target, options: .atomic) }
    }
}
