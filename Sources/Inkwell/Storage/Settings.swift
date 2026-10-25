import Foundation
import SwiftUI

enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var colorScheme: ColorScheme? { self == .light ? .light : self == .dark ? .dark : nil }
}

enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case off, apple, anthropic, openai, openrouter, ollama, lmstudio
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .apple: return "Apple Intelligence (on-device)"
        case .anthropic: return "Claude (Anthropic API key)"
        case .openai: return "OpenAI (API key)"
        case .openrouter: return "OpenRouter (API key)"
        case .ollama: return "Ollama (local)"
        case .lmstudio: return "LM Studio (local)"
        }
    }
    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-opus-5-5"
        case .openai: return "gpt-5-mini"
        case .openrouter: return "anthropic/claude-sonnet-5.5"
        case .ollama: return "llama3.2"
        case .lmstudio: return "local-model"
        default: return ""
        }
    }
    var needsKey: Bool { self == .anthropic || self == .openai || self == .openrouter }
}

/// Persisted app preferences + account list. Stored as JSON in Application Support so the
/// MCP helper process (`Inkwell --mcp`) can read the same file.
struct AppSettings: Codable {
    var accounts: [Account] = []
    var appearance: AppearanceMode = .system
    var undoSendSeconds: Int = 10
    var vimKeys: Bool = false
    var loadRemoteImages: Bool = false
    var allowedImageSenders: [String] = []
    var blockedSenders: [String] = []
    var mutedThreads: [String] = []
    var rules: [Rule] = []
    var showBrandIcons: Bool = true
    var notificationsEnabled: Bool = true
    var playSounds: Bool = true
    var hideOneTimeCodesFromAI: Bool = true
    var signInPopup: Bool = true
    var aiProvider: AIProvider = .off
    var aiModel: String = ""
    var mcpEnabled: Bool = false
    var mcpAccounts: [UUID] = []
    /// When true, MCP sees exactly `mcpAccounts` (possibly none); when false, every enabled account.
    var mcpRestricted: Bool = false
    /// Accounts MCP may read: every enabled one, or only the selection (possibly none).
    func mcpAllows(_ a: Account) -> Bool { a.enabled && (!mcpRestricted || mcpAccounts.contains(a.id)) }
    var sendReadReceiptRequests: Bool = false
    var markReadOnOpen: Bool = true
    var openAtLogin: Bool = false
    var syncDays: Int = 60
    var accentHex: String = Theme.graphiteHex
    var windowBackground: WindowBackground = .solid
    var showAccountPictures: Bool = true
    // Storage clean-up (Settings → Storage)
    var storageMonths: Int = 6
    var storageEntireEmails: Bool = false
    var storageKeepImportant: Bool = true
    var storageAutoClean: Bool = false
}

enum WindowBackground: String, Codable, CaseIterable, Identifiable {
    case solid, glass, clear
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum Paths {
    static var appSupport: URL {
        let u = ProcessInfo.processInfo.environment["INKWELL_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Inkwell", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var settings: URL { appSupport.appendingPathComponent("settings.json") }
    static var database: URL { appSupport.appendingPathComponent("mail.sqlite") }
    static var drafts: URL {
        let u = appSupport.appendingPathComponent("Drafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

enum SettingsStore {
    static func load() -> AppSettings {
        guard let d = try? Data(contentsOf: Paths.settings) else { return AppSettings() }
        do { return try JSONDecoder().decode(AppSettings.self, from: d) }
        catch {
            // Keep a copy rather than silently losing accounts.
            try? d.write(to: Paths.appSupport.appendingPathComponent("settings.unreadable-\(Int(Date().timeIntervalSince1970)).json"))
            return AppSettings()
        }
    }
    static func save(_ s: AppSettings) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(s) { try? d.write(to: Paths.settings, options: .atomic) }
    }
}

// Tolerant decoding: missing keys fall back to defaults so new versions never wipe settings.
extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T { ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback }
}

extension AppSettings {
    enum CodingKeys: String, CodingKey {
        case accounts, appearance, undoSendSeconds, vimKeys, loadRemoteImages, allowedImageSenders, blockedSenders, mutedThreads, rules,
             showBrandIcons, notificationsEnabled, playSounds, hideOneTimeCodesFromAI, signInPopup,
             aiProvider, aiModel, mcpEnabled, mcpAccounts, mcpRestricted, sendReadReceiptRequests, markReadOnOpen, openAtLogin, syncDays,
             accentHex, windowBackground, showAccountPictures, storageMonths, storageEntireEmails, storageKeepImportant, storageAutoClean
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        self.init()
        accounts = c.value(.accounts, d.accounts)
        appearance = c.value(.appearance, d.appearance)
        undoSendSeconds = c.value(.undoSendSeconds, d.undoSendSeconds)
        vimKeys = c.value(.vimKeys, d.vimKeys)
        loadRemoteImages = c.value(.loadRemoteImages, d.loadRemoteImages)
        allowedImageSenders = c.value(.allowedImageSenders, d.allowedImageSenders)
        blockedSenders = c.value(.blockedSenders, d.blockedSenders)
        mutedThreads = c.value(.mutedThreads, d.mutedThreads)
        rules = c.value(.rules, d.rules)
        showBrandIcons = c.value(.showBrandIcons, d.showBrandIcons)
        notificationsEnabled = c.value(.notificationsEnabled, d.notificationsEnabled)
        playSounds = c.value(.playSounds, d.playSounds)
        hideOneTimeCodesFromAI = c.value(.hideOneTimeCodesFromAI, d.hideOneTimeCodesFromAI)
        signInPopup = c.value(.signInPopup, d.signInPopup)
        aiProvider = c.value(.aiProvider, d.aiProvider)
        aiModel = c.value(.aiModel, d.aiModel)
        mcpEnabled = c.value(.mcpEnabled, d.mcpEnabled)
        mcpAccounts = c.value(.mcpAccounts, d.mcpAccounts)
        // Older settings: a non-empty list always meant "only these".
        mcpRestricted = c.value(.mcpRestricted, !mcpAccounts.isEmpty)
        sendReadReceiptRequests = c.value(.sendReadReceiptRequests, d.sendReadReceiptRequests)
        markReadOnOpen = c.value(.markReadOnOpen, d.markReadOnOpen)
        openAtLogin = c.value(.openAtLogin, d.openAtLogin)
        syncDays = c.value(.syncDays, d.syncDays)
        accentHex = c.value(.accentHex, d.accentHex)
        windowBackground = c.value(.windowBackground, d.windowBackground)
        showAccountPictures = c.value(.showAccountPictures, d.showAccountPictures)
        storageMonths = c.value(.storageMonths, d.storageMonths)
        storageEntireEmails = c.value(.storageEntireEmails, d.storageEntireEmails)
        storageKeepImportant = c.value(.storageKeepImportant, d.storageKeepImportant)
        storageAutoClean = c.value(.storageAutoClean, d.storageAutoClean)
    }
}

extension Account {
    enum CodingKeys: String, CodingKey {
        case id, label, displayName, email, username, colorHex, imapHost, imapPort, smtpHost, smtpPort, smtpSecurity, signature, signatureOnReplies,
             aliases, style, enabled, notify, archiveFolder, sentFolder, draftsFolder, trashFolder, spamFolder
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let email: String = c.value(.email, "")
        self.init(id: c.value(.id, UUID()), label: c.value(.label, "Mail"), displayName: c.value(.displayName, ""), email: email,
                  username: c.value(.username, email), imapHost: c.value(.imapHost, ""), smtpHost: c.value(.smtpHost, ""))
        colorHex = c.value(.colorHex, colorHex)
        imapPort = c.value(.imapPort, imapPort)
        smtpPort = c.value(.smtpPort, smtpPort)
        smtpSecurity = c.value(.smtpSecurity, smtpSecurity)
        signature = c.value(.signature, signature)
        signatureOnReplies = c.value(.signatureOnReplies, signatureOnReplies)
        aliases = c.value(.aliases, aliases)
        style = c.value(.style, style)
        enabled = c.value(.enabled, enabled)
        notify = c.value(.notify, notify)
        archiveFolder = c.value(.archiveFolder, archiveFolder)
        sentFolder = c.value(.sentFolder, sentFolder)
        draftsFolder = c.value(.draftsFolder, draftsFolder)
        trashFolder = c.value(.trashFolder, trashFolder)
        spamFolder = c.value(.spamFolder, spamFolder)
    }
}

extension Alias {
    enum CodingKeys: String, CodingKey { case id, email, name, signature, replyTo }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: c.value(.id, UUID()), email: c.value(.email, ""), name: c.value(.name, ""), signature: c.value(.signature, ""), replyTo: c.value(.replyTo, ""))
    }
}
