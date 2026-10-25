import SwiftUI
import EventKit
import QuickLook
import UniformTypeIdentifiers

struct ConversationView: View {
    var thread: ThreadSummary
    @Bindable var store: MailStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accent) private var accent
    @Environment(\.onAccent) private var onAccent
    @Environment(\.accentFill) private var accentFill
    @State private var messages: [MessageRecord] = []
    @State private var parsed: [String: ParsedMessage] = [:]
    @State private var allowRemoteFor: Set<String> = []
    @State private var summary: AISummary?
    @State private var summaryDismissed = false
    @State private var summarizing = false
    @State private var aiError: String?
    @State private var suggestions: [String] = []
    @State private var customSnooze = false
    @State private var quickLookURL: URL?
    @State private var showQuoted: Set<String> = []
    @State private var expandedClassic: Set<String> = []
    @State private var safeOverride = false

    private var account: Account? { store.account(thread.accountId) }
    private var style: ConversationStyle { account?.style ?? .classic }
    private var latestInbound: MessageRecord? { messages.last { !$0.isFromMe } }
    private var counterpart: EmailAddress { latestInbound?.from ?? thread.latest.to.first ?? thread.latest.from }

    var body: some View {
        Card {
            GeometryReader { geo in
                let pad: CGFloat = geo.size.width > 760 ? 56 : 28
                VStack(spacing: 0) {
                    toolbar
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 22) {
                                titleBlock
                                banners
                                if let summary, !summaryDismissed { summaryCard(summary) }
                                if let inv = messages.lazy.compactMap({ parsed[$0.id]?.calendar }).last.flatMap(CalendarInvite.parse),
                                   let m = messages.last(where: { parsed[$0.id]?.calendar != nil }) {
                                    InviteCard(invite: inv, message: m, store: store)
                                }
                                ForEach(messages) { m in
                                    Group { if style == .chat { bubble(m) } else { classicMessage(m) } }.id(m.id)
                                }
                                Color.clear.frame(height: 1).id("bottom")
                            }
                            .padding(.horizontal, pad).padding(.top, 36).padding(.bottom, 16)
                        }
                        .onChange(of: messages.count) { scrollToLatest(proxy) }
                        .onChange(of: parsed.count) { scrollToLatest(proxy) }
                        .onChange(of: style) { scrollToLatest(proxy) }
                    }
                    ComposerBar(store: store, thread: thread, recipientName: counterpart.name.split(separator: " ").first.map(String.init) ?? counterpart.display,
                                suggestions: $suggestions, makeDraft: { quickDraft() })
                        .padding(.horizontal, pad).padding(.top, 6).padding(.bottom, 28)
                }
            }
        }
        .task(id: thread.id + "\(thread.latest.id)") { await load() }
        .sheet(isPresented: $customSnooze) {
            DatePickerSheet(title: "Snooze until…", action: "Snooze") { store.snooze([thread], until: $0) }
        }
        .quickLookPreview($quickLookURL)
    }

    // MARK: loading

    private func load() async {
        Perf.openStart = Perf.uptimeMs()
        messages = store.conversation(thread)
        summary = nil; summaryDismissed = false; suggestions = []; aiError = nil; safeOverride = false
        let need = messages.filter { parsed[$0.id] == nil }
        if !need.isEmpty { parsed.merge(await store.loadBodies(need)) { a, _ in a } }
        Perf.open("bodies parsed (\(messages.count) msgs)")
        store.prefetchNeighbors(of: thread)
        // Debug snapshots must never change real mail state.
        if store.settings.markReadOnOpen && ProcessInfo.processInfo.environment["INKWELL_SNAPSHOT"] == nil {
            let msgs = messages; Task { await store.markReadOnOpen(msgs) }
        }
        if AIService.isEnabled && ProcessInfo.processInfo.environment["INKWELL_SNAPSHOT"] == nil {
            if messages.count >= 2 || (parsed[messages.last?.id ?? ""]?.plainText.count ?? 0) > 600 { await summarize() }
            if let last = messages.last, !last.isFromMe, last.category == .primary { await suggest() }
        }
    }

    /// Chat: newest bubble at the bottom. Classic: top of the newest (expanded) message.
    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        if style == .chat { proxy.scrollTo("bottom", anchor: .bottom) }
        else if messages.count > 1, let last = messages.last { proxy.scrollTo(last.id, anchor: .top) }
    }

    private func setStyle(_ v: ConversationStyle) {
        if let i = store.settings.accounts.firstIndex(where: { $0.id == thread.accountId }) { store.settings.accounts[i].style = v }
    }

    private func bodyItems() -> [(MessageRecord, String)] { messages.map { ($0, parsed[$0.id]?.plainText ?? $0.snippet) } }

    private func summarize() async {
        summarizing = true; defer { summarizing = false }
        do { summary = try await AIService.summarizeStructured(bodyItems()) } catch { aiError = error.localizedDescription }
    }

    private func suggest() async {
        suggestions = (try? await AIService.suggestReplies(bodyItems(), myName: account?.displayName ?? "me")) ?? []
    }

    // MARK: toolbar & title

    private var toolbar: some View {
        HStack(spacing: 4) {
            toolButton("Archive", key: "E") { Task { await store.archive([thread]) } }
            Menu {
                SnoozeMenu { store.snooze([thread], until: $0) }
                Divider()
                Button("Pick Date & Time…") { customSnooze = true }
            } label: { toolLabel("Snooze", key: "H") }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            toolButton(thread.flagged ? "Unflag" : "Flag", key: "F") { Task { await store.toggleFlag([thread]) } }
            toolButton("Trash", key: "#") { Task { await store.trash([thread]) } }
            Menu { moreMenu } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink2)
                    .frame(width: 30, height: 28).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                segment(.classic)
                segment(.chat)
            }
            .padding(2)
            .background(Theme.fieldFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(.horizontal, 28).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func toolLabel(_ title: String, key: String) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(Theme.ink2)
            Text(key).foregroundStyle(Theme.faint)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func toolButton(_ title: String, key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { toolLabel(title, key: key) }.buttonStyle(HoverPlainStyle())
    }

    private func segment(_ v: ConversationStyle) -> some View {
        let sel = style == v
        return Button { withAnimation(.snappy) { setStyle(v) } } label: {
            Text(v.label).font(.system(size: 12, weight: sel ? .semibold : .regular))
                .foregroundStyle(sel ? Theme.ink : Theme.muted)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background {
                    if sel {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.raised)
                            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.08), radius: 1, y: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(thread.latest.subject.isEmpty ? "(no subject)" : thread.latest.subject)
                .font(.system(size: 28, weight: .bold)).tracking(-0.56).foregroundStyle(Theme.ink)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if let account {
                    Text(account.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(account.color)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(account.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                Text(metaLine).font(.system(size: 12)).foregroundStyle(Theme.faint)
            }
        }
    }

    private var metaLine: String {
        var parts = [messages.count == 1 ? "1 message" : "\(max(messages.count, thread.count)) messages"]
        if thread.flagged { parts.append("Flagged") }
        return parts.joined(separator: " · ")
    }

    private var participants: [EmailAddress] {
        var seen = Set<String>(); var out: [EmailAddress] = []
        for m in messages { for a in [m.from] + m.to + m.cc where seen.insert(a.email.lowercased()).inserted { out.append(a) } }
        return out
    }

    @ViewBuilder private var moreMenu: some View {
        if let m = messages.last {
            Button("Reply") { reply(m, all: false) }
            Button("Reply All") { reply(m, all: true) }
            Button("Forward") { forward(m) }
            Divider()
        }
        Button(thread.unread ? "Mark as Read" : "Mark as Unread") { Task { await store.toggleRead([thread]) } }
        Button("Mute Conversation") { Task { await store.mute([thread]) } }
        if let m = latestInbound {
            if !m.listUnsubscribe.isEmpty { Button("Unsubscribe") { Task { await store.unsubscribe(m) } } }
            Button("Block \(m.from.email)") { Task { await store.blockSender(m.from.email) } }
            Button("Report as Spam") { Task { await store.reportSpam([thread]) } }
        }
        Divider()
        if AIService.isEnabled { Button("Summarize") { summaryDismissed = false; Task { await summarize() } } }
        Picker("View as", selection: Binding(get: { style }, set: { setStyle($0) })) { ForEach(ConversationStyle.allCases) { Text($0.label).tag($0) } }
        if let m = messages.last {
            Button("Print…") { if let p = parsed[m.id] { Printer.print(m, p) } }
            Button("Save as .eml…") { saveRaw(m) }
        }
    }

    // MARK: banners

    @ViewBuilder private var banners: some View {
        if !safeOverride, let m = latestInbound, let p = parsed[m.id], let v = Classifier.phishingCheck(from: m.from, headers: p.headers) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("This message may be impersonating \(m.from.name.isEmpty ? m.from.domain : m.from.name).").font(.system(size: 14, weight: .semibold))
                        Text(v.warning + " Don't open its links or reply with passwords, codes or payment details.").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 14) {
                    Button("Report as Spam") { Task { await store.reportSpam([thread]) } }
                    Button("Block Sender…") { Task { await store.blockSender(m.from.email) } }
                    Spacer()
                    Button("It's Safe") { safeOverride = true }.foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundStyle(.red)
                .padding(.leading, 24)
            }
            .padding(14)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.red.opacity(0.2)))
        }
        let cleaned = messages.compactMap { m in parsed[m.id].flatMap { $0.html.isEmpty ? nil : (m, Privacy.clean($0.html)) } }
        let blocked = cleaned.filter { !remoteAllowed($0.0) && $0.1.hasRemoteImages }.map(\.0)
        let trackers = cleaned.reduce(0) { $0 + $1.1.trackersRemoved }
        if !blocked.isEmpty && !isSpamFolder {
            HStack(spacing: 10) {
                Image(systemName: "eye.slash").foregroundStyle(.secondary)
                Text("Images hidden" + (trackers > 0 ? " · \(trackers) tracker\(trackers == 1 ? "" : "s") removed" : "")).font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
                Button("Load images") { loadImages() }.keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Always from sender") { if let m = blocked.last { store.allowImages(from: m.from.email) }; loadImages() }
            }
            .buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(accent)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Theme.field(scheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        if let aiError { Text(aiError).font(.caption).foregroundStyle(.secondary) }
        if summarizing && summary == nil {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Summarizing…").font(.system(size: 13)).foregroundStyle(.secondary) }
        }
    }

    private var isSpamFolder: Bool { thread.messages.contains { $0.folder == account?.spamFolder } }
    private func loadImages() { allowRemoteFor.formUnion(messages.map(\.id)) }
    private func remoteAllowed(_ m: MessageRecord) -> Bool {
        if isSpamFolder { return false }
        return allowRemoteFor.contains(m.id) || store.settings.loadRemoteImages || store.settings.allowedImageSenders.contains(m.from.email.lowercased()) || m.isFromMe
    }

    private func summaryCard(_ s: AISummary) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkle").font(.system(size: 14, weight: .semibold)).foregroundStyle(accent).frame(width: 16).padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                Text(s.text).font(.system(size: 13)).lineSpacing(3).foregroundStyle(Theme.ink2)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                ForEach(s.actions, id: \.self) { a in
                    Label { Text(a).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink) } icon: { Image(systemName: "checkmark.circle").foregroundStyle(accent) }
                }
            }
            Spacer(minLength: 0)
            Button { summaryDismissed = true } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.faint) }
                .buttonStyle(.plain).help("Hide summary")
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.fieldFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: chat style

    @ViewBuilder
    private func bubble(_ m: MessageRecord) -> some View {
        let p = parsed[m.id]
        let mine = m.isFromMe
        let designed = p.map { !$0.html.isEmpty && Privacy.isDesignedCached($0.html) } ?? false
        let hasQuoted = p.map { HTMLText.stripQuoted($0.plainText).count < $0.plainText.trimmingCharacters(in: .whitespacesAndNewlines).count - 20 } ?? false
        VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
            Group {
                if let p {
                    if designed || showQuoted.contains(m.id) {
                        HTMLBody(message: m, parsed: p, allowRemote: remoteAllowed(m))
                            .padding(designed ? 0 : 14)
                            .frame(maxWidth: 640)
                            .background(Theme.bubbleIn(scheme), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.stroke(scheme)))
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(chatText(p)).font(.system(size: 13.5)).lineSpacing(2).textSelection(.enabled)
                                .foregroundStyle(mine ? AnyShapeStyle(onAccent) : AnyShapeStyle(.primary))
                            if !p.visibleAttachments.isEmpty { attachments(p.visibleAttachments, onDark: mine) }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(mine ? AnyShapeStyle(accentFill) : AnyShapeStyle(Theme.bubbleIn(scheme)), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(mine ? .clear : Theme.stroke(scheme)))
                    }
                } else {
                    Text(m.snippet.isEmpty ? "Loading…" : m.snippet).font(.system(size: 13.5)).foregroundStyle(.secondary)
                        .padding(.horizontal, 18).padding(.vertical, 13)
                        .background(Theme.bubbleIn(scheme), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
            }
            .frame(maxWidth: 560, alignment: mine ? .trailing : .leading)
            .contextMenu { messageMenu(m) }
            if hasQuoted && !designed {
                Button { showQuoted.formSymmetricDifference([m.id]) } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .overlay(Capsule().strokeBorder(Theme.stroke(scheme), lineWidth: 1.5))
                }.buttonStyle(.plain).help("Show quoted text")
            }
            Menu { messageMenu(m) } label: {
                HStack(spacing: 4) {
                    Text(timeLabel(m) + (mine ? "" : " · to \(recipientLabel(m))"))
                    if mine { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(accent) }
                    else { Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)) }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    private func timeLabel(_ m: MessageRecord) -> String {
        let cal = Calendar.current
        if Date().timeIntervalSince(m.date) < 90 { return "Just now" }
        if cal.isDateInToday(m.date) { return "Today " + m.date.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(m.date) { return "Yesterday " + m.date.formatted(date: .omitted, time: .shortened) }
        return m.date.formatted(date: .abbreviated, time: .shortened)
    }

    private func recipientLabel(_ m: MessageRecord) -> String {
        let mine = Set(account?.allAddresses ?? [])
        if m.to.contains(where: { mine.contains($0.email.lowercased()) }) { return m.to.count + m.cc.count > 1 ? "me +\(m.to.count + m.cc.count - 1)" : "me" }
        return m.to.first?.display ?? "me"
    }

    private static let chatTextCache = NSCache<NSString, ChatTextBox>()
    final class ChatTextBox { let value: AttributedString; init(_ v: AttributedString) { value = v } }
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Link detection is expensive; bubbles re-render often, so memoize.
    private func chatText(_ p: ParsedMessage) -> AttributedString {
        let key = p.plainText as NSString
        if let hit = Self.chatTextCache.object(forKey: key) { return hit.value }
        let stripped = HTMLText.stripQuoted(p.plainText)
        let text = stripped.isEmpty ? p.plainText : stripped
        var a = AttributedString(text)
        if let det = Self.linkDetector {
            for match in det.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let r = Range(match.range, in: text), let ar = Range(r, in: a), let url = match.url { a[ar].link = url; a[ar].underlineStyle = .single }
            }
        }
        Self.chatTextCache.setObject(ChatTextBox(a), forKey: key)
        return a
    }

    // MARK: classic style

    /// Classic layout: sender line, then the body indented under the name (older messages collapse to a snippet).
    @ViewBuilder
    private func classicMessage(_ m: MessageRecord) -> some View {
        let isLast = m.id == messages.last?.id
        let expanded = isLast || !m.seen || expandedClassic.contains(m.id)
        VStack(alignment: .leading, spacing: 14) {
            if m.id != messages.first?.id { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.bottom, 4) }
            HStack(alignment: .center, spacing: 12) {
                AvatarView(address: m.from, size: 38)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(m.from.display).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                        Text(m.from.email).font(.system(size: 12.5)).foregroundStyle(Theme.faint).lineLimit(1)
                    }
                    Text(expanded ? "to " + recipientLine(m) : m.snippet)
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(timeLabel(m)).font(.system(size: 12)).foregroundStyle(Theme.faint)
                Menu { messageMenu(m) } label: { Image(systemName: "ellipsis").font(.system(size: 12)).foregroundStyle(Theme.faint).frame(width: 20, height: 20) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
            .contentShape(Rectangle())
            .onTapGesture { if !isLast { expandedClassic.formSymmetricDifference([m.id]) } }
            if expanded, let p = parsed[m.id] {
                VStack(alignment: .leading, spacing: 14) {
                    HTMLBody(message: m, parsed: p, allowRemote: remoteAllowed(m))
                    if !p.visibleAttachments.isEmpty { attachments(p.visibleAttachments, onDark: false) }
                }
                .padding(.leading, 50)
            }
        }
    }

    private func recipientLine(_ m: MessageRecord) -> String {
        let to = m.to.map { $0.name.isEmpty ? $0.email : $0.name }
        let cc = m.cc.map { $0.name.isEmpty ? $0.email : $0.name }
        return to.joined(separator: ", ") + (cc.isEmpty ? "" : "  cc " + cc.joined(separator: ", "))
    }

    // MARK: shared bits

    @ViewBuilder private func messageMenu(_ m: MessageRecord) -> some View {
        Button("Reply") { reply(m, all: false) }
        Button("Reply All") { reply(m, all: true) }
        Button("Forward") { forward(m) }
        Divider()
        Button(showQuoted.contains(m.id) ? "Show as Bubble" : "Show Original") { showQuoted.formSymmetricDifference([m.id]) }
        Button(m.seen ? "Mark as Unread" : "Mark as Read") { Task { await store.setSeen([m], !m.seen) } }
        Button("Copy Sender Address") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(m.from.email, forType: .string); Sounds.play(.copy) }
        Divider()
        Text("From: \(m.from.formatted)")
        Text("To: \(m.to.map(\.formatted).joined(separator: ", "))")
        Text(m.date.formatted(date: .complete, time: .standard))
    }

    private func attachments(_ atts: [MIMEPartAttachment], onDark: Bool) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(atts) { a in
                    HStack(spacing: 12) {
                        if a.mimeType.hasPrefix("image/"), let img = NSImage(data: a.data) {
                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).frame(width: 34, height: 40).clipShape(RoundedRectangle(cornerRadius: 5))
                        } else {
                            let ext = (a.filename as NSString).pathExtension.uppercased()
                            Text(ext.isEmpty ? "FILE" : String(ext.prefix(4))).font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color(hex: "#A33A2E"))
                                .frame(width: 34, height: 40)
                                .background(Color(hex: "#F6E2E0").opacity(scheme == .dark ? 0.25 : 1), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            Text(a.filename).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(a.data.count), countStyle: .file)).font(.system(size: 11.5))
                                .foregroundStyle(onDark ? AnyShapeStyle(onAccent.opacity(0.7)) : AnyShapeStyle(Theme.faint))
                        }
                        .frame(maxWidth: 180, alignment: .leading)
                    }
                    .padding(.leading, 10).padding(.trailing, 14).padding(.vertical, 10)
                    .foregroundStyle(onDark ? AnyShapeStyle(onAccent) : AnyShapeStyle(Theme.ink))
                    .background(onDark ? onAccent.opacity(0.18) : Theme.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(onDark ? .clear : Theme.hairline))
                    .contentShape(Rectangle())
                    .onTapGesture { quickLookURL = tempFile(a) }
                    .contextMenu {
                        Button("Quick Look") { quickLookURL = tempFile(a) }
                        Button("Open") { if let u = tempFile(a) { NSWorkspace.shared.open(u) } }
                        Button("Save to Downloads") { save(a) }
                    }
                    .draggable(tempFile(a) ?? URL(fileURLWithPath: "/dev/null"))
                }
            }
        }
    }

    private func tempFile(_ a: MIMEPartAttachment) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("att-\(a.id.uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Per-attachment temp folder: reuse the copy if it's already there.
        let u = dir.appendingPathComponent(SafeFile.basename(a.filename), isDirectory: false)
        if FileManager.default.fileExists(atPath: u.path) { return u }
        return (try? SafeFile.writeUnique(a.data, named: a.filename, in: dir)) ?? u
    }

    private func save(_ a: MIMEPartAttachment) {
        let dl = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        guard let u = try? SafeFile.writeUnique(a.data, named: a.filename, in: dl) else { NSSound.beep(); return }
        NSWorkspace.shared.activateFileViewerSelecting([u])
    }

    private func saveRaw(_ m: MessageRecord) {
        guard let raw = store.db.raw(for: m.id) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (m.subject.isEmpty ? "message" : m.subject.replacingOccurrences(of: "/", with: "-")) + ".eml"
        if panel.runModal() == .OK, let u = panel.url { try? raw.write(to: u) }
    }

    private func reply(_ m: MessageRecord, all: Bool) { store.compose(store.replyDraft(to: m, parsed: parsed[m.id], all: all)) }
    private func forward(_ m: MessageRecord) { store.compose(store.forwardDraft(of: m, parsed: parsed[m.id])) }

    private func quickDraft() -> OutgoingDraft? {
        guard let target = messages.last(where: { !$0.isFromMe }) ?? messages.last else { return nil }
        return store.replyDraft(to: target, parsed: parsed[target.id], all: true)
    }
}

/// The floating "Message …" bar under a conversation.
struct ComposerBar: View {
    var store: MailStore
    var thread: ThreadSummary
    var recipientName: String
    @Binding var suggestions: [String]
    var makeDraft: () -> OutgoingDraft?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accent) private var accent
    @Environment(\.onAccent) private var onAccent
    @Environment(\.accentFill) private var accentFill
    @State private var text = ""
    @State private var files: [URL] = []
    @State private var fromOverride: (UUID, String)?
    @State private var customSendAt = false
    @FocusState private var focused: Bool

    private var fromAccount: Account? { store.account(fromOverride?.0 ?? thread.accountId) }
    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !suggestions.isEmpty && text.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(suggestions, id: \.self) { s in
                            Button { text = s; focused = true } label: {
                                Text(s).lineLimit(1).font(.system(size: 12)).foregroundStyle(accent)
                                    .padding(.horizontal, 11).padding(.vertical, 5)
                                    .background(Theme.pillFill, in: Capsule())
                                    .overlay(Capsule().strokeBorder(Theme.pillStroke))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            if !files.isEmpty {
                HStack(spacing: 6) {
                    ForEach(files, id: \.self) { u in
                        HStack(spacing: 4) {
                            Text(u.lastPathComponent).font(.system(size: 12)).lineLimit(1)
                            Button { files.removeAll { $0 == u } } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(Theme.faint)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Theme.fieldFill, in: Capsule())
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 12) {
                TextField("Reply to \(recipientName)…", text: $text, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13.5))
                    .lineLimit(1...10)
                    .focused($focused)
                    .padding(.vertical, 6)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.command) { send(); return .handled }
                        return .ignored
                    }
                HStack(spacing: 10) {
                    Button { pickFiles() } label: { icon("paperclip") }.buttonStyle(.plain).help("Attach files")
                    Button { expand() } label: { Text("Aa").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.faint).frame(height: 28) }
                        .buttonStyle(.plain).help("Open full composer (formatting, Cc/Bcc)")
                    Menu {
                        ForEach([SnoozeChoice.laterToday, .thisEvening, .tomorrow, .nextWeek]) { c in
                            Button("Send \(c.label) — \(c.subtitle)") { send(at: c.date) }
                        }
                        Divider()
                        Button("Pick Date & Time…") { customSendAt = true }
                    } label: { icon("clock") }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("Send later")
                    if let a = fromAccount, store.accounts.count > 1 || !a.aliases.isEmpty {
                        Menu {
                            ForEach(store.accounts) { acct in
                                Button("\(acct.label) <\(acct.email)>") { fromOverride = (acct.id, acct.email) }
                                ForEach(acct.aliases) { al in Button("\(acct.label) <\(al.email)>") { fromOverride = (acct.id, al.email) } }
                            }
                        } label: {
                            Text(a.label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted).frame(height: 28)
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("Send from")
                    }
                    Text("⌘↩").font(.system(size: 12)).foregroundStyle(Theme.faint)
                    Button { send() } label: {
                        Text("Send").font(.system(size: 13, weight: .semibold)).foregroundStyle(onAccent)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(accentFill.opacity(canSend ? 1 : 0.45), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain).disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(.leading, 16).padding(.trailing, 12).padding(.vertical, 12)
            .background(Theme.composerFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.composerStroke))
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.06), radius: 8, y: 4)
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
        }
        .sheet(isPresented: $customSendAt) { DatePickerSheet(title: "Send later…", action: "Schedule") { send(at: $0) } }
        .onChange(of: thread.id) { text = ""; files = []; fromOverride = nil }
        .dropDestination(for: URL.self) { urls, _ in files += urls; return true }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 13)).foregroundStyle(Theme.faint).frame(height: 28).contentShape(Rectangle())
    }

    private func circle(_ icon: String) -> some View {
        Image(systemName: icon).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary.opacity(0.75))
            .frame(width: 28, height: 28).background(Theme.field(scheme), in: Circle()).overlay(Circle().strokeBorder(Theme.stroke(scheme)))
    }
    private func textLabel(_ t: String) -> some View {
        Text(t).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary.opacity(0.75))
            .frame(width: 28, height: 28).background(Theme.field(scheme), in: Circle()).overlay(Circle().strokeBorder(Theme.stroke(scheme)))
    }

    private func draft() -> OutgoingDraft? {
        guard var d = makeDraft() else { return nil }
        if let f = fromOverride { d.accountId = f.0; d.fromEmail = f.1 }
        d.plain = text + d.plain
        d.html = HTMLText.fromPlain(d.plain)
        d.attachments = files
        return d
    }

    private func send(at date: Date? = nil) {
        guard canSend, var d = draft() else { return }
        d.sendAt = date
        store.queueSend(d)
        text = ""; files = []; suggestions = []
    }

    private func expand() {
        guard var d = draft() else { return }
        d.html = ""
        store.compose(d)
        text = ""; files = []
    }

    private func pickFiles() {
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = false
        if p.runModal() == .OK { files += p.urls }
    }
}

/// HTML body with privacy cleaning applied.
struct HTMLBody: View {
    var message: MessageRecord
    var parsed: ParsedMessage
    var allowRemote: Bool
    @State private var height: CGFloat = 60

    var body: some View {
        let c = HTMLBody.content(parsed)
        MessageWebView(html: c.html, allowRemote: allowRemote, designed: c.designed, inlineImages: c.inline, contentID: message.id, height: $height)
            .frame(height: max(height, 30))
    }

    /// What the web view shows for a message (also used to pre-render the next email).
    static func content(_ parsed: ParsedMessage) -> (html: String, designed: Bool, inline: [String: Data]) {
        let html = parsed.html.isEmpty ? HTMLText.fromPlain(parsed.text) : Privacy.clean(parsed.html).html
        let inline = Dictionary(parsed.attachments.compactMap { a in a.contentId.map { ($0, a.data) } }, uniquingKeysWith: { a, _ in a })
        return (html, !parsed.html.isEmpty && Privacy.isDesignedCached(parsed.html), inline)
    }
}

struct InviteCard: View {
    var invite: CalendarInvite
    var message: MessageRecord
    var store: MailStore
    @State private var added = false
    @State private var responded: CalendarInvite.Response?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Text(invite.start?.formatted(.dateTime.month(.abbreviated)) ?? "").font(.caption2.weight(.bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 2).background(.red)
                Text(invite.start?.formatted(.dateTime.day()) ?? "?").font(.title2.weight(.semibold)).padding(.vertical, 4)
            }
            .frame(width: 52).background(.background, in: RoundedRectangle(cornerRadius: 8)).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(invite.summary).font(.headline)
                if let s = invite.start {
                    Text(invite.allDay ? s.formatted(date: .complete, time: .omitted) : "\(s.formatted(date: .abbreviated, time: .shortened)) – \(invite.end?.formatted(date: .omitted, time: .shortened) ?? "")")
                        .font(.callout)
                }
                if !invite.location.isEmpty { Label(invite.location, systemImage: "mappin.and.ellipse").font(.caption).foregroundStyle(.secondary) }
                if !invite.attendees.isEmpty {
                    Text(invite.attendees.prefix(6).map(\.display).joined(separator: ", ") + (invite.attendees.count > 6 ? " +\(invite.attendees.count - 6)" : ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if invite.method.uppercased() == "REQUEST" {
                    HStack {
                        ForEach([CalendarInvite.Response.accepted, .tentative, .declined], id: \.self) { r in
                            Button(r == .accepted ? "Accept" : r == .tentative ? "Maybe" : "Decline") {
                                responded = r
                                Task { await store.respond(to: invite, message: message, response: r) }
                            }
                            .buttonStyle(.bordered)
                            .tint(responded == r ? .accentColor : nil)
                        }
                        Button(added ? "Added" : "Add to Calendar") { addToCalendar() }.disabled(added)
                    }
                    .controlSize(.small).padding(.top, 4)
                }
            }
            Spacer()
        }
        .padding(14)
        .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private func addToCalendar() {
        let ek = EKEventStore()
        ek.requestWriteOnlyAccessToEvents { granted, _ in
            guard granted else { return }
            let e = EKEvent(eventStore: ek)
            e.title = invite.summary
            e.startDate = invite.start ?? Date()
            e.endDate = invite.end ?? e.startDate.addingTimeInterval(3600)
            e.isAllDay = invite.allDay
            e.location = invite.location
            e.calendar = ek.defaultCalendarForNewEvents
            try? ek.save(e, span: .thisEvent)
            DispatchQueue.main.async { added = true }
        }
    }
}

@MainActor
enum Printer {
    static func print(_ m: MessageRecord, _ p: ParsedMessage) {
        let header = "<p><b>From:</b> \(HTMLText.escape(m.from.formatted))<br><b>To:</b> \(HTMLText.escape(m.to.map(\.formatted).joined(separator: ", ")))<br><b>Date:</b> \(m.date.formatted())<br><b>Subject:</b> \(HTMLText.escape(m.subject))</p><hr>"
        let html = header + (p.html.isEmpty ? HTMLText.fromPlain(p.text) : Privacy.clean(p.html).html)
        guard let attr = NSAttributedString(html: Data(html.utf8), options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) else { return }
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 540, height: 800))
        tv.textStorage?.setAttributedString(attr)
        tv.sizeToFit()
        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.isVerticallyCentered = false
        NSPrintOperation(view: tv, printInfo: info).run()
    }
}
