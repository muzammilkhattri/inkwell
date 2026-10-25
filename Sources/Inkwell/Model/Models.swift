import Foundation
import SwiftUI

enum SMTPSecurity: String, Codable, CaseIterable, Identifiable {
    case ssl, starttls
    var id: String { rawValue }
    var label: String { self == .ssl ? "SSL/TLS" : "STARTTLS" }
}

enum ConversationStyle: String, Codable, CaseIterable, Identifiable {
    case classic, chat
    var id: String { rawValue }
    var label: String { self == .chat ? "Chat" : "Classic" }
}

struct Alias: Codable, Hashable, Identifiable {
    var id = UUID()
    var email: String
    var name: String = ""
    var signature: String = ""
    var replyTo: String = ""
}

struct Account: Codable, Hashable, Identifiable {
    var id = UUID()
    var label: String
    var displayName: String
    var email: String
    var username: String
    var colorHex: String = "#4F7CFF"
    var imapHost: String
    var imapPort: Int = 993
    var smtpHost: String
    var smtpPort: Int = 465
    var smtpSecurity: SMTPSecurity = .ssl
    var signature: String = ""
    var signatureOnReplies: Bool = true
    var aliases: [Alias] = []
    var style: ConversationStyle = .classic
    var enabled: Bool = true
    var notify: Bool = true
    // Server folder names resolved from SPECIAL-USE (filled after first LIST)
    var archiveFolder: String?
    var sentFolder: String?
    var draftsFolder: String?
    var trashFolder: String?
    var spamFolder: String?

    var color: Color { Color(hex: colorHex) }
    var isGmail: Bool { imapHost.contains("gmail") }
    var allAddresses: [String] { [email.lowercased()] + aliases.map { $0.email.lowercased() } }
}

struct ProviderPreset: Identifiable {
    let id: String
    let name: String
    let imapHost: String
    let imapPort: Int
    let smtpHost: String
    let smtpPort: Int
    let smtpSecurity: SMTPSecurity
    let help: String

    static let all: [ProviderPreset] = [
        .init(id: "gmail", name: "Gmail", imapHost: "imap.gmail.com", imapPort: 993, smtpHost: "smtp.gmail.com", smtpPort: 465, smtpSecurity: .ssl,
              help: "Use an App Password: myaccount.google.com → Security → 2-Step Verification → App passwords."),
        .init(id: "icloud", name: "iCloud", imapHost: "imap.mail.me.com", imapPort: 993, smtpHost: "smtp.mail.me.com", smtpPort: 587, smtpSecurity: .starttls,
              help: "Use an app-specific password from account.apple.com → Sign-In and Security. Username is your iCloud email (or the part before @icloud.com)."),
        .init(id: "outlook", name: "Outlook / Microsoft 365", imapHost: "outlook.office365.com", imapPort: 993, smtpHost: "smtp-mail.outlook.com", smtpPort: 587, smtpSecurity: .starttls,
              help: "Needs an app password (account.microsoft.com → Security → Advanced). Some work accounts disable IMAP basic auth."),
        .init(id: "yahoo", name: "Yahoo", imapHost: "imap.mail.yahoo.com", imapPort: 993, smtpHost: "smtp.mail.yahoo.com", smtpPort: 465, smtpSecurity: .ssl,
              help: "Generate an app password in Yahoo Account Security."),
        .init(id: "fastmail", name: "Fastmail", imapHost: "imap.fastmail.com", imapPort: 993, smtpHost: "smtp.fastmail.com", smtpPort: 465, smtpSecurity: .ssl,
              help: "Create an app password in Settings → Privacy & Security → Integrations."),
        .init(id: "other", name: "Other IMAP", imapHost: "", imapPort: 993, smtpHost: "", smtpPort: 465, smtpSecurity: .ssl,
              help: "Enter your provider's IMAP and SMTP server details."),
    ]
}

enum FolderRole: String, Codable {
    case inbox, sent, drafts, trash, spam, archive, all, flagged, other
}

struct MailFolder: Codable, Hashable, Identifiable {
    var id: String { accountId.uuidString + "|" + path }
    var accountId: UUID
    var path: String
    var displayName: String
    var role: FolderRole
    var delimiter: String
    var selectable: Bool
}

enum MailCategory: Int, Codable, CaseIterable, Identifiable {
    case primary = 0, updates = 1, promos = 2
    var id: Int { rawValue }
    var label: String { ["Primary", "Updates", "Promos"][rawValue] }
}

struct EmailAddress: Codable, Hashable {
    var name: String
    var email: String
    var display: String { name.isEmpty ? email : name }
    var formatted: String {
        if name.isEmpty { return email }
        let needsQuote = name.contains(where: { ",;<>@\"".contains($0) })
        let n = needsQuote ? "\"\(name.replacingOccurrences(of: "\"", with: "\\\""))\"" : name
        return "\(MIME.encodeHeaderWord(n)) <\(email)>"
    }
    var domain: String { email.split(separator: "@").last.map { String($0).lowercased() } ?? "" }
}

struct AttachmentInfo: Codable, Hashable {
    var filename: String
    var mimeType: String
    var size: Int
}

struct MessageRecord: Identifiable, Hashable {
    var id: String               // account|folder|uidvalidity|uid
    var accountId: UUID
    var folder: String
    var uid: UInt32
    var messageId: String
    var inReplyTo: String
    var references: String
    var threadKey: String
    var from: EmailAddress
    var to: [EmailAddress]
    var cc: [EmailAddress]
    var replyTo: String
    var subject: String
    var date: Date
    var snippet: String
    var seen: Bool
    var flagged: Bool
    var answered: Bool
    var size: Int
    var category: MailCategory
    var needsReply: Bool
    var listUnsubscribe: String
    var listUnsubscribePost: String
    var hasAttachments: Bool
    var hasBody: Bool
    var isFromMe: Bool
    var attachmentNames: String
}

struct ThreadSummary: Identifiable, Hashable {
    let id: String                      // "<account uuid>|<thread key>", computed once
    var accountId: UUID
    var threadKey: String
    var latest: MessageRecord
    var messages: [MessageRecord]       // messages in this mailbox
    var count: Int
    var sortDate: Double

    init(accountId: UUID, threadKey: String, latest: MessageRecord, messages: [MessageRecord], count: Int, accountKey: String? = nil, sortDate: Double? = nil) {
        id = (accountKey ?? accountId.uuidString) + "|" + threadKey
        self.accountId = accountId
        self.threadKey = threadKey
        self.latest = latest
        self.messages = messages
        self.count = count
        self.sortDate = sortDate ?? latest.date.timeIntervalSince1970
    }
    var unread: Bool { messages.contains { !$0.seen } }
    var flagged: Bool { messages.contains { $0.flagged } }
    var hasAttachments: Bool { messages.contains { $0.hasAttachments } }
    var participants: String {
        var seen = Set<String>(); var names: [String] = []
        for m in messages.sorted(by: { $0.date < $1.date }) {
            let n = m.isFromMe ? "Me" : (m.from.name.split(separator: " ").first.map(String.init) ?? m.from.email)
            if seen.insert(n).inserted { names.append(n) }
        }
        return names.joined(separator: ", ")
    }
}

enum Mailbox: Hashable {
    case allInboxes
    case toReply
    case snoozed
    case scheduled
    case flagged
    case reminders
    case folder(accountId: UUID, path: String)
    case accountInbox(UUID)
    case allRole(FolderRole)   // unified Sent / Spam / Trash across accounts

    var title: String {
        switch self {
        case .allInboxes: return "All Inboxes"
        case .toReply: return "To Reply"
        case .snoozed: return "Snoozed"
        case .scheduled: return "Scheduled"
        case .flagged: return "Flagged"
        case .reminders: return "Awaiting Reply"
        case .folder(_, let p): return MUTF7.decode(p).split(separator: "/").last.map(String.init) ?? p
        case .accountInbox: return "Inbox"
        case .allRole(let r): return r == .sent ? "Sent" : r == .spam ? "Spam" : r == .trash ? "Trash" : r.rawValue.capitalized
        }
    }
}

enum InboxTab: String, CaseIterable, Identifiable {
    case primary = "Primary", updates = "Updates", promos = "Promos", all = "All"
    var id: String { rawValue }
    var category: MailCategory? {
        switch self { case .all: return nil; case .primary: return .primary; case .updates: return .updates; case .promos: return .promos }
    }
}

struct Rule: Codable, Identifiable, Hashable {
    enum Field: String, Codable, CaseIterable, Identifiable { case from, subject, body, hasAttachment, mailingList; var id: String { rawValue }
        var label: String { ["from": "Sender contains", "subject": "Subject contains", "body": "Text contains", "hasAttachment": "Has attachment", "mailingList": "Is mailing list"][rawValue]! } }
    enum Action: String, Codable, CaseIterable, Identifiable { case move, archive, markRead, trash; var id: String { rawValue }
        var label: String { ["move": "Move to folder", "archive": "Archive", "markRead": "Mark as read", "trash": "Move to Trash"][rawValue]! } }
    var id = UUID()
    var name: String = "New Rule"
    var enabled = true
    var accountId: UUID?   // nil = all accounts
    var field: Field = .from
    var value: String = ""
    var action: Action = .archive
    var targetFolder: String = ""

    func matches(_ m: MessageRecord, body: String) -> Bool {
        let v = value.lowercased()
        switch field {
        case .from: return !v.isEmpty && (m.from.email.lowercased().contains(v) || m.from.name.lowercased().contains(v))
        case .subject: return !v.isEmpty && m.subject.lowercased().contains(v)
        case .body: return !v.isEmpty && (body.lowercased().contains(v) || m.snippet.lowercased().contains(v))
        case .hasAttachment: return m.hasAttachments
        case .mailingList: return !m.listUnsubscribe.isEmpty
        }
    }
}

struct OutgoingDraft: Codable, Identifiable, Hashable {
    var id = UUID()
    var accountId: UUID?
    var fromEmail: String = ""
    var to: String = ""
    var cc: String = ""
    var bcc: String = ""
    var subject: String = ""
    var html: String = ""
    var plain: String = ""
    var rtfData: Data?
    var inReplyTo: String = ""
    var references: String = ""
    var quotedHTML: String = ""
    var quotedPlain: String = ""
    var replyThreadKey: String = ""
    var replyToMessageId: String = ""
    var attachments: [URL] = []
    var sendAt: Date?
    var remindAfter: TimeInterval?
    var requestReadReceipt = false
    var draftedBy: String?
    var serverDraftMessageId: String?
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0x4F7CFF
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .systemBlue
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

let accountPalette = ["#4F7CFF", "#FF6B4A", "#22B07D", "#A25CF2", "#F2B33D", "#EC4899", "#14B8C4", "#64748B"]
