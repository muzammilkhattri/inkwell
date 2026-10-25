import AppKit
import SwiftUI

/// Sign-in popup: a black card that floats just below the notch (or the top-centre of the
/// screen on Macs without one). Only shown for one-time codes and sign-in links.
@MainActor
final class CodePopup {
    static let shared = CodePopup()

    struct Item: Identifiable, Equatable {
        enum Kind: Equatable { case code(String), link(URL) }
        let id = UUID()
        var messageId: String
        var sender: EmailAddress
        var kind: Kind
        var date = Date()
    }

    @Observable final class Model {
        var items: [Item] = []          // first is on screen, the rest peek behind it
        var visible = false
        var hovering = false
        var copied = false
        var leaving = false
    }

    let model = Model()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private static let size = CGSize(width: 420, height: 240)
    private static let showSeconds = 8.0

    private var screen: NSScreen? { NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main }

    // MARK: entry points

    /// Picks the newest sign-in code or link out of a batch of new mail, if any.
    func show(newMail msgs: [MessageRecord]) {
        guard MailStore.shared.settings.signInPopup else { return }
        for m in msgs.sorted(by: { $0.date > $1.date }) where m.category != .promos {
            guard let secret = Notifier.signIn(for: m) else { continue }
            switch secret {
            case .code(let c): present(Item(messageId: m.id, sender: m.from, kind: .code(c)))
            case .link(let u): present(Item(messageId: m.id, sender: m.from, kind: .link(u)))
            }
            return
        }
    }

    func preview() {
        present(Item(messageId: "", sender: EmailAddress(name: "Acme", email: "security@acme.com"), kind: .code("482913")))
    }

    // MARK: actions

    func copy(_ item: Item) {
        guard case .code(let code) = item.kind else { return }
        MailStore.shared.useSignInCode(code, messageId: item.messageId.isEmpty ? nil : item.messageId)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { model.copied = true }
        scheduleHide(after: 1.2, waitForHover: false)
    }

    func openLink(_ item: Item) {
        guard case .link(let url) = item.kind else { return }
        NSWorkspace.shared.open(url)
        if !item.messageId.isEmpty { Notifier.shared.dismiss(messageId: item.messageId) }
        dismiss()
    }

    func viewEmail(_ item: Item) {
        dismiss()
        guard !item.messageId.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        for w in NSApp.windows where w.title == "Inkwell" { w.makeKeyAndOrderFront(nil) }
        let store = MailStore.shared
        if let m = store.db.message(id: item.messageId) {
            store.mailbox = .allInboxes
            store.selection = [store.thread(for: m).id]
        }
    }

    func archive(_ item: Item) {
        let store = MailStore.shared
        if let m = store.db.message(id: item.messageId) { Task { await store.archive([store.thread(for: m)]) } }
        Notifier.shared.dismiss(messageId: item.messageId)
        dismiss()
    }

    // MARK: presentation

    private func setup() {
        guard panel == nil else { return }
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovable = false
        p.level = .statusBar + 1
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingView(rootView: CodePopupView(model: model))
        host.sizingOptions = []
        p.contentView = host
        panel = p
    }

    private func place() {
        guard let screen, let panel else { return }
        // Just below the notch / menu bar.
        let top = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : screen.frame.maxY - screen.visibleFrame.maxY
        let s = Self.size
        panel.setFrame(NSRect(x: (screen.frame.midX - s.width / 2).rounded(), y: screen.frame.maxY - top - s.height, width: s.width, height: s.height), display: true)
    }

    private func present(_ item: Item) {
        setup()
        if model.visible && !model.leaving {
            // Already showing one: newest goes on top, the older one peeks behind.
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                model.items.insert(item, at: 0)
                if model.items.count > 3 { model.items.removeLast(model.items.count - 3) }
                model.copied = false
            }
        } else {
            hideTask?.cancel()
            place()
            panel?.orderFrontRegardless()
            model.items = [item]
            model.copied = false
            model.leaving = false
            withAnimation(.spring(response: 0.48, dampingFraction: 0.76)) { model.visible = true }
        }
        scheduleHide(after: Self.showSeconds)
    }

    private func scheduleHide(after seconds: Double, waitForHover: Bool = true) {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            while waitForHover && self.model.hovering && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
            }
            if waitForHover && !Task.isCancelled { try? await Task.sleep(for: .seconds(1)) }
            if !Task.isCancelled { self.next() }
        }
    }

    /// Done with the front item: reveal the one behind it, or leave.
    private func next() {
        if model.items.count > 1 {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                model.items.removeFirst()
                model.copied = false
            }
            scheduleHide(after: Self.showSeconds)
        } else {
            dismiss()
        }
    }

    /// Leaving: shrink to a pill, then slide up into the notch.
    func dismiss() {
        hideTask?.cancel()
        guard model.visible else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { model.leaving = true; model.hovering = false }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(380))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.22)) { self.model.visible = false }
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled, !self.model.visible else { return }
            self.model.items = []
            self.model.leaving = false
            self.panel?.orderOut(nil)
        }
    }
}

// MARK: - Views

private enum PopupPalette {
    static let body = Color.black
    static let raised = Color(red: 0.11, green: 0.11, blue: 0.118)       // #1C1C1E
    static let peek = Color(red: 0.173, green: 0.173, blue: 0.18)        // #2C2C2E
    static let primary = Color(red: 0.96, green: 0.96, blue: 0.97)       // #F5F5F7
    static let secondary = Color(red: 0.557, green: 0.557, blue: 0.576)  // #8E8E93
    static let success = Color(red: 0.19, green: 0.82, blue: 0.345)      // #30D158
    static let link = Color(red: 0.04, green: 0.518, blue: 1)            // #0A84FF
}

private struct CodePopupView: View {
    @Bindable var model: CodePopup.Model

    var body: some View {
        VStack(spacing: 0) {
            if model.visible, let item = model.items.first {
                ZStack(alignment: .top) {
                    if model.items.count > 1 && !model.leaving { peek(model.items[1]) }
                    Group {
                        if model.leaving { LeavingPill(item: item, copied: model.copied) }
                        else { PopupCard(item: item, model: model) }
                    }
                    .id(item.id)
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                }
                .transition(.asymmetric(insertion: .scale(scale: 0.6, anchor: .top).combined(with: .opacity),
                                        removal: .scale(scale: 0.4, anchor: .top).combined(with: .offset(y: -30)).combined(with: .opacity)))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The next item, tucked behind the front card.
    private func peek(_ item: CodePopup.Item) -> some View {
        VStack {
            Spacer()
            Text("+\(model.items.count - 1) · \(item.sender.display) \(item.kind.isCode ? "code" : "link")")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Color(white: 0.68))
                .lineLimit(1).padding(.bottom, 5).padding(.horizontal, 16)
        }
        .frame(width: 296, height: 40)
        .background(PopupPalette.peek, in: UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18, style: .continuous))
        .offset(y: cardHeight - 16)
    }

    private var cardHeight: CGFloat { 106 + (model.hovering ? 42 : 0) }
}

private extension CodePopup.Item.Kind {
    var isCode: Bool { if case .code = self { return true }; return false }
}

private struct PopupCard: View {
    var item: CodePopup.Item
    @Bindable var model: CodePopup.Model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AvatarView(address: item.sender, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.sender.display).font(.system(size: 13, weight: .semibold)).foregroundStyle(PopupPalette.primary)
                    Text("\(item.kind.isCode ? "Verification code" : "Sign-in link") · \(item.date.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 12)).foregroundStyle(PopupPalette.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            HStack(alignment: .center) {
                switch item.kind {
                case .code(let code):
                    Text(Self.grouped(code))
                        .font(.system(size: 30, weight: .semibold).monospacedDigit()).tracking(4)
                        .foregroundStyle(PopupPalette.primary).lineLimit(1).minimumScaleFactor(0.6)
                        .textSelection(.enabled)
                    Spacer(minLength: 12)
                    pill(model.copied ? "Copied" : "Copy", icon: model.copied ? "checkmark" : nil,
                         fill: model.copied ? PopupPalette.success : PopupPalette.primary, text: .black) { CodePopup.shared.copy(item) }
                case .link(let url):
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sign in to \(Self.site(url))").font(.system(size: 19, weight: .semibold)).foregroundStyle(PopupPalette.primary)
                        Text(url.host() ?? url.absoluteString).font(.system(size: 12)).foregroundStyle(PopupPalette.link)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 12)
                    pill("Open", icon: nil, fill: PopupPalette.link, text: .white) { CodePopup.shared.openLink(item) }
                }
            }
            if model.hovering {
                HStack(spacing: 8) {
                    action("View email") { CodePopup.shared.viewEmail(item) }
                    action("Archive") { CodePopup.shared.archive(item) }
                    Button { CodePopup.shared.dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(PopupPalette.secondary)
                            .frame(width: 34, height: 30).background(PopupPalette.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 16)
        .frame(width: 330)
        .background(PopupPalette.body, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 16, y: 10)
        .contentShape(RoundedRectangle(cornerRadius: 24))
        .onHover { h in withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { model.hovering = h } }
        .environment(\.colorScheme, .dark)
    }

    private func pill(_ title: String, icon: String?, fill: Color, text: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .bold)) }
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(text)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(fill, in: Capsule())
            .contentTransition(.interpolate)
        }
        .buttonStyle(.plain)
    }

    private func action(_ title: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(PopupPalette.primary)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(PopupPalette.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// "482913" → "482 913", "12345678" → "1234 5678".
    static func grouped(_ code: String) -> String {
        guard code.allSatisfy(\.isNumber), code.count >= 6, code.count % 2 == 0 || code.count % 3 == 0 else { return code }
        let n = code.count % 3 == 0 ? 3 : code.count / 2
        var out = ""
        for (i, ch) in code.enumerated() { if i > 0 && i % n == 0 { out.append(" ") }; out.append(ch) }
        return out
    }

    /// "acme.slack.com" → "Acme", "accounts.google.com" → "Google".
    static func site(_ url: URL) -> String {
        let parts = (url.host() ?? "").split(separator: ".").map(String.init)
        let skip: Set<String> = ["www", "accounts", "login", "auth", "account", "signin", "id", "app", "mail", "email", "links", "link", "click"]
        let name = parts.dropLast().first { !skip.contains($0) } ?? parts.first ?? "your account"
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}

private struct LeavingPill: View {
    var item: CodePopup.Item
    var copied: Bool

    var body: some View {
        HStack {
            if case .code(let code) = item.kind {
                Text(PopupCard.grouped(code)).font(.system(size: 13, weight: .semibold).monospacedDigit()).tracking(1.3)
                    .foregroundStyle(PopupPalette.primary)
            } else {
                Text(item.sender.display).font(.system(size: 13, weight: .semibold)).foregroundStyle(PopupPalette.primary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if copied {
                Text("Copied").font(.system(size: 11, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 9).padding(.vertical, 4).background(PopupPalette.success, in: Capsule())
            }
        }
        .padding(.leading, 14).padding(.trailing, 6)
        .frame(width: 196, height: 34)
        .background(PopupPalette.body, in: Capsule())
        .shadow(color: .black.opacity(0.2), radius: 10, y: 6)
    }
}

// MARK: - Debug render

extension CodePopup {
    /// `INKWELL_POPUP_SNAPSHOT=/path.png`: renders every popup state to one PNG.
    static func debugRender(to path: String) {
        func model(_ items: [Item], copied: Bool = false, hovering: Bool = false, leaving: Bool = false) -> Model {
            let m = Model(); m.items = items; m.visible = true; m.copied = copied; m.hovering = hovering; m.leaving = leaving; return m
        }
        let code = Item(messageId: "", sender: EmailAddress(name: "Google", email: "no-reply@accounts.google.com"), kind: .code("482913"))
        let gh = Item(messageId: "", sender: EmailAddress(name: "GitHub", email: "noreply@github.com"), kind: .code("71204588"))
        let link = Item(messageId: "", sender: EmailAddress(name: "Slack", email: "no-reply@slack.com"), kind: .link(URL(string: "https://acme.slack.com/z/abc")!))
        let states = [model([code]), model([code], copied: true), model([link]), model([code], hovering: true), model([code, gh]), model([code], copied: true, leaving: true)]
        let grid = VStack(spacing: 12) {
            ForEach(0..<2) { r in
                HStack(spacing: 12) {
                    ForEach(0..<3) { c in
                        CodePopupView(model: states[r * 3 + c])
                            .frame(width: size.width, height: 200)
                            .background(LinearGradient(colors: [Color(red: 0.62, green: 0.71, blue: 0.78), Color(red: 0.79, green: 0.73, blue: 0.66)], startPoint: .top, endPoint: .bottom))
                            .overlay(alignment: .top) { UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10).fill(.black).frame(width: 180, height: 6) }
                    }
                }
            }
        }
        .padding(12)
        let r = ImageRenderer(content: grid)
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Debug: one popup below a mock notch on a wallpaper strip, for the README.
    static func debugRenderHero(code: Bool, to path: String) {
        let item = code
            ? Item(messageId: "", sender: EmailAddress(name: "Google", email: "no-reply@accounts.google.com"), kind: .code("482913"))
            : Item(messageId: "", sender: EmailAddress(name: "Slack", email: "no-reply@slack.com"), kind: .link(URL(string: "https://acme.slack.com/z/sign-in")!))
        let m = Model(); m.items = [item]; m.visible = true
        let scene = CodePopupView(model: m)
            .frame(width: size.width, height: 200)
            .frame(width: 760, height: 150, alignment: .top)
            .background(LinearGradient(colors: [Color(red: 0.36, green: 0.45, blue: 0.62), Color(red: 0.78, green: 0.66, blue: 0.62)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(alignment: .top) { UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12).fill(.black).frame(width: 200, height: 8) }
        let r = ImageRenderer(content: scene)
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}
