import SwiftUI
import UniformTypeIdentifiers
import ServiceManagement

struct SettingsView: View {
    @Bindable var store: MailStore
    var body: some View {
        TabView {
            AccountsSettings(store: store).tabItem { Label("Accounts", systemImage: "at") }
            GeneralSettings(store: store).tabItem { Label("General", systemImage: "gearshape") }
            SignaturesSettings(store: store).tabItem { Label("Signatures", systemImage: "signature") }
            RulesSettings(store: store).tabItem { Label("Rules", systemImage: "line.3.horizontal.decrease.circle") }
            SubscriptionsSettings(store: store).tabItem { Label("Subscriptions", systemImage: "newspaper") }
            PopupSettings(store: store).tabItem { Label("Popup", systemImage: "key.viewfinder") }
            AISettings(store: store).tabItem { Label("AI", systemImage: "sparkles") }
            StorageSettings(store: store).tabItem { Label("Storage", systemImage: "internaldrive") }
            ShortcutsSettings(store: store).tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 720, height: 560)
        .tint(Theme.accent(store.settings.accentHex))
        .environment(\.accentFill, Theme.accentFill(store.settings.accentHex))
    }
}

// MARK: General

struct GeneralSettings: View {
    @Bindable var store: MailStore
    var body: some View {
        Form {
            Section("Appearance") {
                LabeledContent {
                    Picker("", selection: $store.settings.appearance) {
                        Text("System").tag(AppearanceMode.system); Text("Light").tag(AppearanceMode.light); Text("Dark").tag(AppearanceMode.dark)
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                } label: {
                    VStack(alignment: .leading) { Text("Theme"); Text("Dark leaves designed mail as its sender built it.").font(.caption).foregroundStyle(.secondary) }
                }
                LabeledContent {
                    HStack(spacing: 7) {
                        ForEach(Theme.accentPalette, id: \.self) { hex in
                            Button { store.settings.accentHex = hex } label: {
                                Circle().fill(Color(hex: hex)).frame(width: 18, height: 18)
                                    .overlay(Circle().strokeBorder(.white, lineWidth: store.settings.accentHex == hex ? 2.5 : 0).padding(2))
                                    .overlay(Circle().strokeBorder(Color(hex: hex).opacity(0.6), lineWidth: store.settings.accentHex == hex ? 1.5 : 0))
                            }.buttonStyle(.plain)
                        }
                    }
                } label: {
                    VStack(alignment: .leading) { Text("Accent color"); Text("Buttons, selection and unread marks.").font(.caption).foregroundStyle(.secondary) }
                }
                LabeledContent {
                    Picker("", selection: $store.settings.windowBackground) {
                        ForEach(WindowBackground.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                } label: {
                    VStack(alignment: .leading) { Text("Window background"); Text("Glass lets your desktop show through.").font(.caption).foregroundStyle(.secondary) }
                }
                Toggle(isOn: $store.settings.showAccountPictures) {
                    VStack(alignment: .leading) { Text("Show account pictures"); Text("Each account wears its owner's photo or logo.").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Picker("Undo Send", selection: $store.settings.undoSendSeconds) {
                Text("Off").tag(0); Text("5 seconds").tag(5); Text("10 seconds").tag(10); Text("20 seconds").tag(20); Text("30 seconds").tag(30)
            }
            Toggle("Mark messages as read after viewing them", isOn: $store.settings.markReadOnOpen)
            Section("Privacy") {
                Toggle("Load remote images automatically", isOn: $store.settings.loadRemoteImages)
                Text("Tracking pixels and link trackers are always removed. Remote images never load in Spam.").font(.caption).foregroundStyle(.secondary)
                Toggle("Show brand icons from sender websites", isOn: $store.settings.showBrandIcons)
                Toggle("Request read receipts by default", isOn: $store.settings.sendReadReceiptRequests)
                if !store.settings.allowedImageSenders.isEmpty {
                    LabeledContent("Always load images from") {
                        Menu("\(store.settings.allowedImageSenders.count) senders") {
                            ForEach(store.settings.allowedImageSenders, id: \.self) { s in Button("Remove \(s)") { store.settings.allowedImageSenders.removeAll { $0 == s } } }
                        }.fixedSize()
                    }
                }
            }
            Section("Notifications") {
                Toggle("Show notifications for new mail", isOn: $store.settings.notificationsEnabled)
                Toggle("Play sounds (new mail, sent, copy, sign-in codes)", isOn: $store.settings.playSounds)
                    .onChange(of: store.settings.playSounds) { if store.settings.playSounds { Sounds.play(.success) } }
                Toggle("Hide one-time codes in notification text", isOn: $store.settings.hideOneTimeCodesFromAI)
            }
            Section("Startup") {
                Toggle("Open at login (keeps Send Later and snoozes running)", isOn: Binding(get: { store.settings.openAtLogin }, set: { v in
                    store.settings.openAtLogin = v
                    if v { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                }))
            }
            Section("Blocked Senders") {
                if store.settings.blockedSenders.isEmpty { Text("No blocked senders").foregroundStyle(.secondary) }
                ForEach(store.settings.blockedSenders, id: \.self) { s in
                    HStack { Text(s); Spacer(); Button("Unblock") { store.settings.blockedSenders.removeAll { $0 == s } } }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Accounts

struct AccountsSettings: View {
    @Bindable var store: MailStore
    @State private var selected: UUID?
    @State private var adding = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selected) {
                    ForEach(store.settings.accounts) { a in
                        HStack {
                            Circle().fill(a.color).frame(width: 10, height: 10)
                            VStack(alignment: .leading) {
                                Text(a.label).font(.callout)
                                Text(a.email).font(.caption).foregroundStyle(.secondary)
                            }
                        }.tag(a.id)
                    }
                }
                HStack {
                    Button { adding = true } label: { Image(systemName: "plus") }
                    Button {
                        if let s = selected { store.removeAccount(s); selected = nil }
                    } label: { Image(systemName: "minus") }.disabled(selected == nil)
                    Spacer()
                }
                .buttonStyle(.borderless).padding(8)
            }
            .frame(minWidth: 200, maxWidth: 240)
            Group {
                if let s = selected, let i = store.settings.accounts.firstIndex(where: { $0.id == s }) {
                    AccountEditor(account: $store.settings.accounts[i], store: store)
                } else {
                    ContentUnavailableView("Select an account", systemImage: "at", description: Text("Or press + to add Gmail, iCloud, Outlook, Yahoo, Fastmail or any IMAP account."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $adding) { AddAccountSheet(store: store) { selected = $0 } }
        .onAppear { selected = selected ?? store.settings.accounts.first?.id; if store.settings.accounts.isEmpty { adding = true } }
    }
}

struct AccountEditor: View {
    @Binding var account: Account
    var store: MailStore
    @State private var password = ""
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        Form {
            Section("Account") {
                TextField("Label", text: $account.label)
                TextField("Your name", text: $account.displayName)
                TextField("Email", text: $account.email)
                ColorPicker("Color", selection: Binding(get: { account.color }, set: { account.colorHex = $0.hexString }), supportsOpacity: false)
                Picker("Conversations", selection: $account.style) {
                    ForEach(ConversationStyle.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
                Toggle("Notifications", isOn: $account.notify)
                Toggle("Enabled", isOn: $account.enabled)
            }
            Section("Picture") {
                HStack {
                    AccountAvatar(account: account, size: 44)
                    Button("Choose Picture…") {
                        let p = NSOpenPanel(); p.allowedContentTypes = [.image]
                        if p.runModal() == .OK, let u = p.url { AccountPictures.set(account.id, from: u); account.colorHex = account.colorHex }
                    }
                    Text("Shown in the sidebar and composer.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Aliases") {
                ForEach($account.aliases) { $al in
                    VStack(alignment: .leading) {
                        HStack {
                            TextField("Email", text: $al.email)
                            TextField("Name", text: $al.name)
                            Button { account.aliases.removeAll { $0.id == al.id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                        TextField("Reply-To (optional)", text: $al.replyTo)
                        TextField("Signature (optional)", text: $al.signature, axis: .vertical).lineLimit(1...4)
                    }
                    .padding(.vertical, 4)
                }
                Button("Add Alias") { account.aliases.append(Alias(email: "")) }
            }
            Section("Server") {
                TextField("Username", text: $account.username)
                SecureField("Password / app password", text: $password).onSubmit { savePassword() }
                HStack { TextField("IMAP server", text: $account.imapHost); TextField("Port", value: $account.imapPort, format: .number.grouping(.never)).frame(width: 70) }
                HStack {
                    TextField("SMTP server", text: $account.smtpHost)
                    TextField("Port", value: $account.smtpPort, format: .number.grouping(.never)).frame(width: 70)
                    Picker("", selection: $account.smtpSecurity) { ForEach(SMTPSecurity.allCases) { Text($0.label).tag($0) } }.labelsHidden().frame(width: 110)
                }
                HStack {
                    Button("Save Password") { savePassword() }.disabled(password.isEmpty)
                    Button("Test Connection") { test() }.disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                    if let testResult { Text(testResult).font(.caption).foregroundStyle(testResult.hasPrefix("✓") ? .green : .red).lineLimit(3) }
                }
            }
            Section("Folders") {
                LabeledContent("Archive", value: account.archiveFolder.map(MUTF7.decode) ?? "—")
                LabeledContent("Sent", value: account.sentFolder.map(MUTF7.decode) ?? "—")
                LabeledContent("Drafts", value: account.draftsFolder.map(MUTF7.decode) ?? "—")
                LabeledContent("Trash", value: account.trashFolder.map(MUTF7.decode) ?? "—")
                LabeledContent("Spam", value: account.spamFolder.map(MUTF7.decode) ?? "—")
            }
        }
        .formStyle(.grouped)
    }

    private func savePassword() {
        Keychain.setPassword(password, for: account)
        password = ""
        store.stopAccount(account.id); store.startAccount(account)
        testResult = "✓ Saved"
    }

    private func test() {
        testing = true; testResult = nil
        let pw = password.isEmpty ? Keychain.password(for: account) : password
        Task {
            do { try await AccountConnection.test(account: account, password: pw); testResult = "✓ IMAP and SMTP sign-in worked" }
            catch { testResult = error.localizedDescription }
            testing = false
        }
    }
}

struct AddAccountSheet: View {
    var store: MailStore
    var onAdded: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var preset = ProviderPreset.all[0]
    @State private var name = NSFullUserName()
    @State private var email = ""
    @State private var password = ""
    @State private var username = ""
    @State private var imapHost = ""
    @State private var imapPort = 993
    @State private var smtpHost = ""
    @State private var smtpPort = 465
    @State private var security = SMTPSecurity.ssl
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Account").font(.title2.weight(.semibold))
            Picker("Provider", selection: Binding(get: { preset.id }, set: { id in preset = ProviderPreset.all.first { $0.id == id }!; applyPreset() })) {
                ForEach(ProviderPreset.all) { Text($0.name).tag($0.id) }
            }.pickerStyle(.segmented).labelsHidden()
            Text(preset.help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Your name", text: $name)
                TextField("Email", text: $email).textContentType(.emailAddress)
                SecureField(preset.id == "other" ? "Password" : "App password", text: $password)
                if preset.id == "other" || preset.id == "icloud" {
                    TextField("Username (if different)", text: $username)
                }
                if preset.id == "other" {
                    HStack { TextField("IMAP server", text: $imapHost); TextField("Port", value: $imapPort, format: .number.grouping(.never)).frame(width: 70) }
                    HStack {
                        TextField("SMTP server", text: $smtpHost)
                        TextField("Port", value: $smtpPort, format: .number.grouping(.never)).frame(width: 70)
                        Picker("", selection: $security) { ForEach(SMTPSecurity.allCases) { Text($0.label).tag($0) } }.labelsHidden().frame(width: 110)
                    }
                }
            }
            .formStyle(.grouped)
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button { add() } label: { if working { ProgressView().controlSize(.small) } else { Text("Sign In") } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(email.isEmpty || password.isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear(perform: applyPreset)
        .onChange(of: email) { if preset.id == "other", imapHost.isEmpty || imapHost.hasPrefix("imap."), let d = email.split(separator: "@").last { imapHost = "imap.\(d)"; smtpHost = "smtp.\(d)" } }
    }

    private func applyPreset() {
        imapHost = preset.imapHost; imapPort = preset.imapPort
        smtpHost = preset.smtpHost; smtpPort = preset.smtpPort; security = preset.smtpSecurity
    }

    private func add() {
        working = true; error = nil
        let user = username.isEmpty ? email : username
        let label = preset.id == "other" ? (email.split(separator: "@").last.map(String.init) ?? "Mail") : preset.name.components(separatedBy: " ").first!
        let account = Account(label: store.settings.accounts.contains { $0.label == label } ? email : label, displayName: name, email: email.trimmingCharacters(in: .whitespaces),
                              username: user.trimmingCharacters(in: .whitespaces),
                              colorHex: accountPalette[store.settings.accounts.count % accountPalette.count],
                              imapHost: imapHost, imapPort: imapPort, smtpHost: smtpHost, smtpPort: smtpPort, smtpSecurity: security)
        Task {
            do {
                try await AccountConnection.test(account: account, password: password)
                store.addAccount(account, password: password)
                onAdded(account.id)
                dismiss()
            } catch {
                var isAuth = false
                if case MailError.auth = error { isAuth = true }
                self.error = error.localizedDescription + (preset.id == "gmail" && isAuth ? "\nGmail needs 2-Step Verification on and an App Password (not your normal password)." : "")
            }
            working = false
        }
    }
}

// MARK: Rules

struct RulesSettings: View {
    @Bindable var store: MailStore
    var body: some View {
        VStack(alignment: .leading) {
            Text("Rules run on new mail before it reaches your inbox. They're applied on the server, so every device sees the result.")
                .font(.caption).foregroundStyle(.secondary).padding([.horizontal, .top])
            Form {
                ForEach($store.settings.rules) { $r in
                    Section {
                        HStack {
                            Toggle("", isOn: $r.enabled).labelsHidden()
                            TextField("Name", text: $r.name)
                            Button { store.settings.rules.removeAll { $0.id == r.id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                        Picker("Account", selection: $r.accountId) {
                            Text("All accounts").tag(UUID?.none)
                            ForEach(store.settings.accounts) { Text($0.label).tag(UUID?.some($0.id)) }
                        }
                        HStack {
                            Picker("When", selection: $r.field) { ForEach(Rule.Field.allCases) { Text($0.label).tag($0) } }
                            if r.field != .hasAttachment && r.field != .mailingList { TextField("", text: $r.value) }
                        }
                        HStack {
                            Picker("Then", selection: $r.action) { ForEach(Rule.Action.allCases) { Text($0.label).tag($0) } }
                            if r.action == .move {
                                Picker("", selection: $r.targetFolder) {
                                    Text("Choose…").tag("")
                                    ForEach(folders(for: r.accountId), id: \.self) { Text(MUTF7.decode($0)).tag($0) }
                                }.labelsHidden()
                            }
                        }
                    }
                }
                Button("Add Rule") { store.settings.rules.append(Rule()) }
            }
            .formStyle(.grouped)
        }
    }

    private func folders(for acct: UUID?) -> [String] {
        let ids = acct.map { [$0] } ?? store.settings.accounts.map(\.id)
        return Array(Set(ids.flatMap { store.folders[$0]?.filter(\.selectable).map(\.path) ?? [] })).sorted()
    }
}

// MARK: Subscriptions

struct SubscriptionsSettings: View {
    var store: MailStore
    struct Sender: Identifiable { var id: String { email }; var email: String; var name: String; var count: Int; var latestId: String; var hasUnsub: Bool }
    @State private var senders: [Sender] = []
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Everyone who sends you mailing-list mail, by volume.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(width: 180)
            }
            .padding([.horizontal, .top])
            List(senders.filter { filter.isEmpty || $0.email.localizedCaseInsensitiveContains(filter) || $0.name.localizedCaseInsensitiveContains(filter) }) { s in
                HStack {
                    AvatarView(address: EmailAddress(name: s.name, email: s.email), size: 26)
                    VStack(alignment: .leading) { Text(s.name.isEmpty ? s.email : s.name); Text(s.email).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Text("\(s.count)").monospacedDigit().foregroundStyle(.secondary)
                    if s.hasUnsub {
                        Button("Unsubscribe") { if let m = store.db.message(id: s.latestId) { Task { await store.unsubscribe(m); load() } } }
                    }
                    Button("Block") { Task { await store.blockSender(s.email); load() } }
                }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        senders = store.db.query("""
            SELECT from_email, MAX(from_name), COUNT(*), MAX(id), MAX(list_unsub <> '') FROM messages
            WHERE from_me=0 AND (list_unsub <> '' OR COALESCE(gm_cat, category) > 0) GROUP BY lower(from_email) ORDER BY COUNT(*) DESC LIMIT 500
            """) { Sender(email: $0.string(0), name: $0.string(1), count: $0.int(2), latestId: $0.string(3), hasUnsub: $0.bool(4)) }
            .filter { !store.settings.blockedSenders.contains($0.email.lowercased()) }
    }
}

// MARK: Sign-in popup

struct PopupSettings: View {
    @Bindable var store: MailStore
    var body: some View {
        Form {
            Toggle("Show sign-in codes and links below the notch", isOn: $store.settings.signInPopup)
            Text("Only one-time codes and magic sign-in links pop up. Click Copy, or hover to view or archive the email. On Macs without a notch it appears at the top centre of the screen.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Preview") { CodePopup.shared.preview() }
                .disabled(!store.settings.signInPopup)
        }
        .formStyle(.grouped)
    }
}

// MARK: AI

struct AISettings: View {
    @Bindable var store: MailStore
    @State private var key = ""
    @State private var activity: [AIActivity] = []
    @State private var testResult: String?
    private var exe: String { Bundle.main.executablePath ?? "/Applications/Inkwell.app/Contents/MacOS/Inkwell" }

    var body: some View {
        Form {
            Section("AI model") {
                Picker("Provider", selection: $store.settings.aiProvider) { ForEach(AIProvider.allCases) { Text($0.label).tag($0) } }
                if store.settings.aiProvider != .off && store.settings.aiProvider != .apple {
                    TextField("Model", text: $store.settings.aiModel, prompt: Text(store.settings.aiProvider.defaultModel))
                }
                if store.settings.aiProvider.needsKey {
                    HStack {
                        SecureField(Keychain.get("ai-key-\(store.settings.aiProvider.rawValue)") == nil ? "API key" : "API key (saved in Keychain)", text: $key)
                        Button("Save") { Keychain.set(key, for: "ai-key-\(store.settings.aiProvider.rawValue)"); key = "" }.disabled(key.isEmpty)
                    }
                }
                if store.settings.aiProvider != .off {
                    HStack {
                        Button("Test") { test() }
                        if let testResult { Text(testResult).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                }
                Text("Used for thread summaries, suggested replies and Rewrite. Smart tabs, To Reply and phishing checks always run on-device without AI.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Let AI apps use your mail (MCP)") {
                Toggle("Turn on Inkwell MCP", isOn: $store.settings.mcpEnabled)
                if store.settings.mcpEnabled {
                    ForEach(store.settings.accounts) { a in
                        Toggle(a.email, isOn: Binding(get: { store.settings.mcpAllows(a) || (!a.enabled && store.settings.mcpAccounts.contains(a.id)) }, set: { on in
                            // Switching off the last account leaves none shared, never "all".
                            var ids = store.settings.mcpRestricted ? store.settings.mcpAccounts : store.settings.accounts.map(\.id)
                            if on { if !ids.contains(a.id) { ids.append(a.id) } } else { ids.removeAll { $0 == a.id } }
                            store.settings.mcpAccounts = ids
                            store.settings.mcpRestricted = true
                        }))
                    }
                    Toggle("Hide one-time codes and sign-in links from AI apps", isOn: $store.settings.hideOneTimeCodesFromAI)
                    command("Claude Code", "claude mcp add --scope user inkwell -- \"\(exe)\" --mcp")
                    command("Codex", "codex mcp add inkwell -- \"\(exe)\" --mcp")
                    command("Cursor / LM Studio / Claude Desktop (mcp.json)", "{ \"mcpServers\": { \"inkwell\": { \"command\": \"\(exe)\", \"args\": [\"--mcp\"] } } }")
                    Text("AI apps can read, search, draft, archive, move, flag, snooze and mute. They can't delete mail or touch Spam/Trash. Sending, rules, unsubscribe and blocking always ask you first.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if store.settings.mcpEnabled {
                Section("Activity") {
                    if activity.isEmpty { Text("No AI actions yet").foregroundStyle(.secondary) }
                    ForEach(activity) { a in
                        HStack {
                            VStack(alignment: .leading) {
                                Text("\(a.app) · \(a.action)").font(.callout)
                                Text(a.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(a.date.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            if !a.undone && ["Archived", "Marked read", "Marked unread", "Flagged", "Unflagged", "Snoozed", "Muted"].contains(a.action) || a.action.hasPrefix("Moved") {
                                Button("Undo") { Task { await store.undoActivity(a.id); activity = store.aiActivity() } }.disabled(a.undone)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { activity = store.aiActivity() }
    }

    private func command(_ title: String, _ cmd: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold))
            HStack {
                Text(cmd).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(3)
                Spacer()
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cmd, forType: .string); Sounds.play(.copy) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
            }
        }
    }

    private func test() {
        testResult = "Testing…"
        Task {
            do { testResult = "✓ " + (try await AIService.complete(system: "Reply with one short friendly sentence.", prompt: "Say hello to the user of a mail app.", maxTokens: 100)) }
            catch { testResult = error.localizedDescription }
        }
    }
}

// MARK: Shortcuts

struct ShortcutsSettings: View {
    @Bindable var store: MailStore
    let rows: [(String, String)] = [
        ("⌘K", "Search & commands"), ("⌘N / C", "New message"), ("R / ⌘R", "Reply"), ("A / ⇧⌘R", "Reply all"), ("F / ⇧⌘F", "Forward"),
        ("E", "Archive"), ("# / ⌘⌫", "Move to Trash"), ("U / ⇧⌘U", "Toggle read"), ("S / ⇧⌘L", "Flag"), ("H", "Snooze until tomorrow"),
        ("M", "Mute"), ("J / ↓", "Next conversation"), ("K / ↑", "Previous conversation"), ("/", "Search"), ("⌘↩", "Send"),
        ("⌘Z", "Undo send / archive / move"), ("⇧⌘I", "Load images"), ("⇧⌘N", "Check for new mail"), ("⌘1…⌘6", "Mailboxes"),
    ]
    var body: some View {
        Form {
            Toggle("Single-key shortcuts (J/K, E, R, #…)", isOn: $store.settings.vimKeys)
            Section {
                ForEach(rows, id: \.0) { r in LabeledContent(r.1) { Text(r.0).font(.system(.body, design: .monospaced)) } }
            }
        }
        .formStyle(.grouped)
    }
}


// MARK: Signatures

struct SignaturesSettings: View {
    @Bindable var store: MailStore
    var body: some View {
        Form {
            ForEach($store.settings.accounts) { $a in
                Section {
                    TextEditor(text: $a.signature).font(.system(size: 13)).frame(height: 70)
                    Toggle("Add to replies", isOn: $a.signatureOnReplies)
                    ForEach($a.aliases) { $al in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(al.email).font(.caption).foregroundStyle(.secondary)
                            TextField("Signature for \(al.email)", text: $al.signature, axis: .vertical).lineLimit(1...4)
                        }
                    }
                } header: {
                    HStack { AccountAvatar(account: a, size: 18); Text("\(a.label) — \(a.email)") }
                }
            }
            if store.settings.accounts.isEmpty { Text("Add an account first.").foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
    }
}
