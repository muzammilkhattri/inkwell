import Foundation
import UserNotifications
import AppKit

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private var center: UNUserNotificationCenter? { Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current() }

    func setup() {
        guard let center else { return }
        center.delegate = self
        let copy = UNNotificationAction(identifier: "COPY_CODE", title: "Copy Code")
        let open = UNNotificationAction(identifier: "OPEN_LINK", title: "Open Link")
        let archive = UNNotificationAction(identifier: "ARCHIVE", title: "Archive")
        let read = UNNotificationAction(identifier: "MARK_READ", title: "Mark as Read")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "CODE", actions: [copy], intentIdentifiers: []),
            UNNotificationCategory(identifier: "LINK", actions: [open], intentIdentifiers: []),
            UNNotificationCategory(identifier: "MAIL", actions: [archive, read], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func notifyNewMail(_ m: MessageRecord, account: Account) {
        guard let center else { return }
        let c = UNMutableNotificationContent()
        c.title = m.from.display
        c.subtitle = m.subject
        // The app plays its own new-mail / sign-in cue; don't stack the system sound on top.
        c.sound = MailStore.shared.settings.playSounds ? nil : .default
        c.userInfo = ["messageId": m.id]
        c.threadIdentifier = m.threadKey
        switch Notifier.signIn(for: m) {
        case .code(let code):
            c.categoryIdentifier = "CODE"
            c.userInfo["code"] = code
            c.body = MailStore.shared.settings.hideOneTimeCodesFromAI ? "Sign-in code received · Copy Code" : "Code: \(code)"
        case .link(let link):
            c.categoryIdentifier = "LINK"
            c.userInfo["link"] = link.absoluteString
            c.body = "Sign-in link received · Open Link"
        case nil:
            c.categoryIdentifier = "MAIL"
            c.body = m.snippet
        }
        center.add(UNNotificationRequest(identifier: m.id, content: c, trigger: nil))
    }

    static func signIn(for m: MessageRecord) -> Classifier.SignIn? {
        let parsed = Database.shared.raw(for: m.id).map(MIME.parse)
        return Classifier.signIn(subject: m.subject, html: parsed?.html ?? "", text: parsed?.plainText ?? m.snippet,
                                  bulk: !m.listUnsubscribe.isEmpty)
    }

    /// Removes a delivered banner once the user acted on the same mail elsewhere (e.g. the sign-in popup).
    func dismiss(messageId: String) {
        center?.removeDeliveredNotifications(withIdentifiers: [messageId])
    }

    func notifySnoozeWake(_ m: MessageRecord) {
        guard let center else { return }
        let c = UNMutableNotificationContent()
        c.title = "⏰ Back from snooze"
        c.subtitle = m.from.display
        c.body = m.subject
        c.sound = .default
        c.userInfo = ["messageId": m.id]
        center.add(UNNotificationRequest(identifier: "snooze-" + m.id, content: c, trigger: nil))
    }

    func notifyReminder(subject: String) {
        guard let center else { return }
        let c = UNMutableNotificationContent()
        c.title = "No reply yet"
        c.body = subject
        c.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let code = info["code"] as? String
        let link = info["link"] as? String
        let mid = info["messageId"] as? String
        await MainActor.run {
            let store = MailStore.shared
            switch action {
            case "COPY_CODE":
                if let code { store.useSignInCode(code, messageId: mid) }
            case "OPEN_LINK":
                if let link, let u = URL(string: link) { NSWorkspace.shared.open(u) }
            case "ARCHIVE":
                if let mid, let m = store.db.message(id: mid) { Task { await store.archive([store.thread(for: m)]) } }
            case "MARK_READ":
                if let mid, let m = store.db.message(id: mid) { Task { await store.setSeen([m], true) } }
            default:
                NSApp.activate(ignoringOtherApps: true)
                if let mid, let m = store.db.message(id: mid) {
                    store.mailbox = .allInboxes
                    store.selection = [store.thread(for: m).id]
                }
            }
        }
    }
}

extension MailStore {
    /// Copies a sign-in code and archives its message: a used code doesn't need to stay in the inbox.
    func useSignInCode(_ code: String, messageId: String?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        Sounds.play(.copy)
        copiedCodes.insert(code)
        guard let messageId else { return }
        Notifier.shared.dismiss(messageId: messageId)
        if let m = db.message(id: messageId) { Task { await archive([thread(for: m)]) } }
    }
}
