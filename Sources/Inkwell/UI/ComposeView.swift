import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: Rich text editor

final class EditorController {
    weak var textView: NSTextView?

    func toggleTrait(_ trait: NSFontTraitMask) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        let fm = NSFontManager.shared
        if range.length == 0 {
            var attrs = tv.typingAttributes
            let f = (attrs[.font] as? NSFont) ?? .systemFont(ofSize: 14)
            attrs[.font] = fm.traits(of: f).contains(trait) ? fm.convert(f, toNotHaveTrait: trait) : fm.convert(f, toHaveTrait: trait)
            tv.typingAttributes = attrs
            return
        }
        let first = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) ?? .systemFont(ofSize: 14)
        let remove = fm.traits(of: first).contains(trait)
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { v, r, _ in
            let f = (v as? NSFont) ?? .systemFont(ofSize: 14)
            storage.addAttribute(.font, value: remove ? fm.convert(f, toNotHaveTrait: trait) : fm.convert(f, toHaveTrait: trait), range: r)
        }
        storage.endEditing()
        tv.didChangeText()
    }

    func toggleUnderline() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        guard range.length > 0 else { return }
        let has = (storage.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int ?? 0) != 0
        storage.addAttribute(.underlineStyle, value: has ? 0 : NSUnderlineStyle.single.rawValue, range: range)
        tv.didChangeText()
    }

    func resize(by delta: CGFloat) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange().length > 0 ? tv.selectedRange() : NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { v, r, _ in
            let f = (v as? NSFont) ?? .systemFont(ofSize: 14)
            storage.addAttribute(.font, value: NSFontManager.shared.convert(f, toSize: max(9, min(36, f.pointSize + delta))), range: r)
        }
        storage.endEditing()
        tv.didChangeText()
    }

    func list(numbered: Bool) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let ns = storage.string as NSString
        let pr = ns.paragraphRange(for: tv.selectedRange())
        var lines: [String] = []
        ns.substring(with: pr).enumerateLines { l, _ in lines.append(l) }
        if lines.isEmpty { lines = [""] }
        let isList = lines.allSatisfy { $0.hasPrefix("• ") || $0.range(of: "^\\d+\\. ", options: .regularExpression) != nil }
        let new = lines.enumerated().map { i, l -> String in
            if isList { return l.replacingOccurrences(of: "^(• |\\d+\\. )", with: "", options: .regularExpression) }
            return (numbered ? "\(i + 1). " : "• ") + l
        }.joined(separator: "\n") + (ns.substring(with: pr).hasSuffix("\n") ? "\n" : "")
        if tv.shouldChangeText(in: pr, replacementString: new) {
            storage.replaceCharacters(in: pr, with: NSAttributedString(string: new, attributes: tv.typingAttributes))
            tv.didChangeText()
        }
    }

    func insert(_ s: String) {
        guard let tv = textView else { return }
        tv.insertText(s, replacementRange: tv.selectedRange())
    }
}

struct RichTextEditor: NSViewRepresentable {
    @Binding var text: NSAttributedString
    var controller: EditorController
    var onFiles: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isRichText = true
        tv.allowsUndo = true
        tv.importsGraphics = false
        tv.isAutomaticSpellingCorrectionEnabled = true
        tv.isContinuousSpellCheckingEnabled = true
        tv.isAutomaticLinkDetectionEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = true
        tv.font = .systemFont(ofSize: 14)
        tv.textContainerInset = NSSize(width: 14, height: 12)
        tv.typingAttributes = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.textColor]
        tv.drawsBackground = false
        scroll.drawsBackground = false
        tv.delegate = context.coordinator
        tv.textStorage?.setAttributedString(text)
        tv.registerForDraggedTypes([.fileURL])
        controller.textView = tv
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv); tv.setSelectedRange(NSRange(location: 0, length: 0)) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if !context.coordinator.editing && tv.attributedString() != text {
            tv.textStorage?.setAttributedString(text)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        var editing = false
        init(_ p: RichTextEditor) { parent = p }
        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            editing = true
            parent.text = tv.attributedString()
            DispatchQueue.main.async { self.editing = false }
        }
    }
}

// MARK: Recipient field with autocomplete

struct RecipientField: View {
    var label: String
    @Binding var text: String
    var db: Database
    @State private var suggestions: [EmailAddress] = []
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onChange(of: text) { updateSuggestions() }
                .popover(isPresented: Binding(get: { focused && !suggestions.isEmpty }, set: { if !$0 { suggestions = [] } }), arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(suggestions, id: \.email) { s in
                            Button { pick(s) } label: {
                                HStack {
                                    AvatarView(address: s, size: 22)
                                    VStack(alignment: .leading) {
                                        Text(s.name.isEmpty ? s.email : s.name).font(.callout)
                                        if !s.name.isEmpty { Text(s.email).font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(width: 320)
                    .padding(.vertical, 6)
                }
        }
    }

    private var currentToken: String {
        text.split(separator: ",", omittingEmptySubsequences: false).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    private func updateSuggestions() {
        let t = currentToken
        suggestions = t.count >= 2 && !t.contains("<") ? db.contacts(matching: t) : []
    }

    private func pick(_ a: EmailAddress) {
        var parts = text.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if !parts.isEmpty { parts.removeLast() }
        parts.append(a.formatted)
        text = parts.filter { !$0.isEmpty }.joined(separator: ", ") + ", "
        suggestions = []
    }
}

// MARK: Compose window

struct ComposeView: View {
    let draftId: UUID
    @Bindable var store: MailStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft = OutgoingDraft()
    @State private var body_ = NSAttributedString(string: "")
    @State private var loaded = false
    @State private var showCc = false
    @State private var showQuoted = false
    @State private var sent = false
    @State private var discarded = false
    @State private var rewriting = false
    @State private var aiError: String?
    @State private var customSendAt = false
    @State private var customRemind = false
    @State private var dropTargeted = false
    @State private var saveTask: Task<Void, Never>?
    /// The upload to the Drafts folder in flight (one at a time per draft).
    @State private var serverSave: Task<Void, Never>?
    /// Content last mirrored to the server, without the server id, so a change to the id alone
    /// doesn't trigger yet another upload.
    @State private var serverSaved: OutgoingDraft?
    private let editor = EditorController()

    var body: some View {
        VStack(spacing: 0) {
            fields
            Divider()
            if let by = draft.draftedBy {
                HStack {
                    Label("Drafted by \(by)", systemImage: "sparkles").font(.caption).foregroundStyle(.purple)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.top, 6)
            }
            formatBar
            RichTextEditor(text: $body_, controller: editor) { addAttachments($0) }
                .frame(minHeight: 200)
            if !draft.quotedHTML.isEmpty {
                DisclosureGroup(isExpanded: $showQuoted) {
                    ScrollView { Text(draft.quotedPlain).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                        .frame(maxHeight: 160)
                } label: { Text("Quoted text").font(.caption).foregroundStyle(.secondary) }
                .padding(.horizontal, 14).padding(.bottom, 6)
            }
            if !draft.attachments.isEmpty { attachmentRow }
            if let aiError { Text(aiError).font(.caption).foregroundStyle(.red).padding(.horizontal, 14) }
            Divider()
            bottomBar
        }
        .frame(minWidth: 560, minHeight: 460)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .overlay(Label("Drop to attach", systemImage: "paperclip").font(.title3).padding().background(.regularMaterial, in: Capsule()))
                    .padding(6)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { addAttachments([url]) } }
                }
            }
            return true
        }
        .navigationTitle(draft.subject.isEmpty ? "New Message" : draft.subject)
        .onAppear(perform: load)
        .onChange(of: draft) { scheduleSave() }
        .onChange(of: body_) { scheduleSave() }
        .onDisappear(perform: closing)
        .sheet(isPresented: $customSendAt) {
            DatePickerSheet(title: "Send later…", action: "Schedule") { d in draft.sendAt = d; send() }
        }
        .sheet(isPresented: $customRemind) {
            DatePickerSheet(title: "Remind me if no reply by…", action: "Set Reminder") { d in draft.remindAfter = d.timeIntervalSinceNow }
        }
    }

    // MARK: sections

    private var fields: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("From").foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
                Picker("", selection: Binding(get: { "\(draft.accountId?.uuidString ?? "")|\(draft.fromEmail)" }, set: { v in
                    let parts = v.split(separator: "|", maxSplits: 1).map(String.init)
                    draft.accountId = UUID(uuidString: parts.first ?? ""); draft.fromEmail = parts.count > 1 ? parts[1] : ""
                })) {
                    ForEach(store.accounts) { a in
                        Text("\(a.displayName) <\(a.email)>").tag("\(a.id.uuidString)|\(a.email)")
                        ForEach(a.aliases) { al in Text("\(al.name.isEmpty ? a.displayName : al.name) <\(al.email)>").tag("\(a.id.uuidString)|\(al.email)") }
                    }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                Spacer()
                Button(showCc ? "Hide Cc/Bcc" : "Cc/Bcc") { showCc.toggle() }.buttonStyle(.link).font(.caption)
            }
            RecipientField(label: "To", text: $draft.to, db: store.db)
            if showCc || !draft.cc.isEmpty || !draft.bcc.isEmpty {
                RecipientField(label: "Cc", text: $draft.cc, db: store.db)
                RecipientField(label: "Bcc", text: $draft.bcc, db: store.db)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Subject").foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
                TextField("", text: $draft.subject).textFieldStyle(.plain).font(.body.weight(.medium))
            }
        }
        .padding(14)
    }

    private var formatBar: some View {
        HStack(spacing: 2) {
            Group {
                Button { editor.toggleTrait(.boldFontMask) } label: { Image(systemName: "bold") }.keyboardShortcut("b", modifiers: .command).help("Bold ⌘B")
                Button { editor.toggleTrait(.italicFontMask) } label: { Image(systemName: "italic") }.keyboardShortcut("i", modifiers: .command).help("Italic ⌘I")
                Button { editor.toggleUnderline() } label: { Image(systemName: "underline") }.keyboardShortcut("u", modifiers: .command).help("Underline ⌘U")
                Divider().frame(height: 14)
                Button { editor.list(numbered: false) } label: { Image(systemName: "list.bullet") }.help("Bulleted list")
                Button { editor.list(numbered: true) } label: { Image(systemName: "list.number") }.help("Numbered list")
                Divider().frame(height: 14)
                Button { editor.resize(by: -2) } label: { Image(systemName: "textformat.size.smaller") }.help("Smaller")
                Button { editor.resize(by: 2) } label: { Image(systemName: "textformat.size.larger") }.help("Larger")
            }
            .buttonStyle(.borderless)
            .frame(minWidth: 26)
            Spacer()
            if AIService.isEnabled {
                Menu {
                    ForEach(AIService.RewriteStyle.allCases) { s in Button(s.rawValue) { rewrite(s) } }
                    Menu("Translate to…") {
                        ForEach(["English", "Spanish", "French", "German", "Italian", "Portuguese", "Dutch", "Japanese", "Chinese", "Korean", "Arabic", "Urdu", "Hindi", "Russian", "Turkish"], id: \.self) { l in
                            Button(l) { rewrite(.translate, language: l) }
                        }
                    }
                } label: {
                    if rewriting { ProgressView().controlSize(.small) } else { Label("Rewrite", systemImage: "sparkles") }
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var attachmentRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(draft.attachments, id: \.self) { u in
                    HStack(spacing: 4) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: u.path)).resizable().frame(width: 16, height: 16)
                        Text(u.lastPathComponent).font(.caption).lineLimit(1)
                        Button { draft.attachments.removeAll { $0 == u } } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button { pickFiles() } label: { Image(systemName: "paperclip") }.buttonStyle(.borderless).help("Attach files")
            Menu {
                Picker("Remind me if no reply", selection: Binding(get: { draft.remindAfter ?? 0 }, set: { draft.remindAfter = $0 == 0 ? nil : $0 })) {
                    Text("Off").tag(TimeInterval(0))
                    Text("In 1 day").tag(TimeInterval(86400))
                    Text("In 3 days").tag(TimeInterval(3 * 86400))
                    Text("In 1 week").tag(TimeInterval(7 * 86400))
                    if let r = draft.remindAfter, ![86400, 3 * 86400, 7 * 86400].contains(r) { Text("Custom").tag(r) }
                }
                Button("Pick a date…") { customRemind = true }
                Divider()
                Toggle("Request read receipt", isOn: $draft.requestReadReceipt)
            } label: {
                Image(systemName: draft.remindAfter == nil ? "bell" : "bell.badge.fill")
            }
            .menuStyle(.borderlessButton).fixedSize().help("Remind me if no reply")
            Button(role: .destructive) { discard() } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Discard draft")
            Spacer()
            if let at = draft.sendAt { Text("Sends \(at.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
            Menu {
                ForEach([SnoozeChoice.laterToday, .thisEvening, .tomorrow, .nextWeek]) { c in
                    Button("\(c.label) — \(c.subtitle)") { draft.sendAt = c.date; send() }
                }
                Divider()
                Button("Pick Date & Time…") { customSendAt = true }
            } label: { Image(systemName: "clock") }
            .menuStyle(.borderlessButton).fixedSize().help("Send later")
            Button { send() } label: { Label("Send", systemImage: "paperplane.fill") }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draft.to.trimmingCharacters(in: .whitespaces).isEmpty && draft.cc.isEmpty && draft.bcc.isEmpty)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    // MARK: logic

    private func load() {
        guard !loaded else { return }
        loaded = true
        draft = store.drafts[draftId] ?? store.localDrafts().first { $0.id == draftId } ?? OutgoingDraft(id: draftId)
        if let rtf = draft.rtfData, let a = NSAttributedString(rtf: rtf, documentAttributes: nil) {
            body_ = a
        } else {
            body_ = NSAttributedString(string: draft.plain, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.textColor])
        }
        showCc = !draft.cc.isEmpty || !draft.bcc.isEmpty
    }

    private func syncBody() {
        draft.plain = body_.string
        draft.rtfData = body_.rtf(from: NSRange(location: 0, length: body_.length))
        draft.html = Self.html(from: body_)
    }

    static func html(from a: NSAttributedString) -> String {
        // Export with neutral colors so dark-mode text isn't sent as white.
        let m = NSMutableAttributedString(attributedString: a)
        m.removeAttribute(.foregroundColor, range: NSRange(location: 0, length: m.length))
        m.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: m.length))
        guard let data = try? m.data(from: NSRange(location: 0, length: m.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue]),
              let html = String(data: data, encoding: .utf8) else { return HTMLText.fromPlain(a.string) }
        let style = html.range(of: "<style[\\s\\S]*?</style>", options: .regularExpression).map { String(html[$0]) } ?? ""
        let bodyContent: String = {
            guard let s = html.range(of: "<body[^>]*>", options: .regularExpression), let e = html.range(of: "</body>") else { return html }
            return String(html[s.upperBound..<e.lowerBound])
        }()
        return style.replacingOccurrences(of: "font-family: '.AppleSystemUIFont'", with: "font-family: -apple-system, Helvetica, Arial, sans-serif")
            .replacingOccurrences(of: "'.AppleSystemUIFont'", with: "-apple-system, Helvetica, Arial, sans-serif") + bodyContent
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, !sent, !discarded else { return }
            syncBody()
            store.saveLocalDraft(draft)
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, !sent, !discarded, hasContent else { return }
            var content = draft; content.serverDraftMessageId = nil
            guard content != serverSaved else { return }
            await serverSave?.value
            guard !Task.isCancelled, !sent, !discarded else { return }
            let job = uploadDraft(draft, content: content)
            serverSave = job
            await job.value
        }
    }

    /// Uploads `snapshot` to the Drafts folder, then merges back only the new server id: the
    /// user may have edited, sent or discarded the draft while the upload was in flight.
    private func uploadDraft(_ snapshot: OutgoingDraft, content: OutgoingDraft?) -> Task<Void, Never> {
        Task { @MainActor in
            let saved = await store.saveServerDraft(snapshot)
            guard let mid = saved.serverDraftMessageId, mid != snapshot.serverDraftMessageId else { return }
            if sent || discarded {
                // Finished after the draft was sent or thrown away: remove the copy just uploaded.
                if let a = saved.accountId.flatMap(store.account) { await store.deleteServerDraft(account: a, messageId: mid) }
                return
            }
            if let content { serverSaved = content }
            draft.serverDraftMessageId = mid
            store.saveLocalDraft(draft)
        }
    }

    private var hasContent: Bool {
        !body_.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.subject.isEmpty || !draft.to.isEmpty || !draft.attachments.isEmpty
    }

    private func send() {
        syncBody()
        sent = true
        saveTask?.cancel()
        store.queueSend(draft)
        dismiss()
    }

    private func discard() {
        discarded = true
        saveTask?.cancel()
        store.drafts[draft.id] = nil
        store.deleteLocalDraft(draft.id)
        if let mid = draft.serverDraftMessageId, let a = draft.accountId.flatMap(store.account) {
            Task { await store.deleteServerDraft(account: a, messageId: mid) }
        }
        dismiss()
    }

    private func closing() {
        saveTask?.cancel()
        guard !sent, !discarded else { return }
        syncBody()
        let d = draft
        if hasContent {
            store.saveLocalDraft(d)
            let prior = serverSave
            Task { @MainActor in
                await prior?.value  // never two uploads of one draft at once
                var latest = d
                if let id = store.drafts[d.id]?.serverDraftMessageId { latest.serverDraftMessageId = id }
                let saved = await store.saveServerDraft(latest)
                // Merge just the server id: the draft may have been reopened, edited or sent since.
                if var cur = store.drafts[d.id] {
                    cur.serverDraftMessageId = saved.serverDraftMessageId
                    store.saveLocalDraft(cur)
                }
            }
            store.showToast("Draft saved")
        } else {
            store.drafts[d.id] = nil
            store.deleteLocalDraft(d.id)
        }
    }

    private func addAttachments(_ urls: [URL]) {
        for u in urls where !draft.attachments.contains(u) { draft.attachments.append(u) }
    }

    private func pickFiles() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        if p.runModal() == .OK { addAttachments(p.urls) }
    }

    private func rewrite(_ style: AIService.RewriteStyle, language: String? = nil) {
        let text = body_.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        rewriting = true; aiError = nil
        Task {
            defer { rewriting = false }
            do {
                let out = try await AIService.rewrite(text, style: style, language: language)
                body_ = NSAttributedString(string: out, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.textColor])
            } catch { aiError = error.localizedDescription }
        }
    }
}
