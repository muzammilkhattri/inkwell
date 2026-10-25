import SwiftUI
import AppKit

/// Visual tokens for the card-based "glass" look.
enum Theme {
    static let cardRadius: CGFloat = 18
    static let gap: CGFloat = 10
    static let rowRadius: CGFloat = 8

    // Graphite (light) / Inky (dark) design tokens. Inky: true-black ground, near-black
    // cards with a faint edge, white text and one cobalt accent.
    static let ink = dynamic(light: "#16181D", dark: "#FFFFFF")
    static let ink2 = dynamic(light: "#3A3D44", dark: "#CFCFD4")      // read rows, toolbar labels
    static let muted = dynamic(light: "#6B6E76", dark: "#8A8A8F")     // counts, snippets, meta
    static let faint = dynamic(light: "#8A8D94", dark: "#5E5E63")     // placeholders, read times
    static let hairline = dynamic(light: "#E4E5E8", dark: "#1C1C1F")
    static let fieldFill = dynamic(light: "#F5F5F7", dark: "#141416")
    static let selectedRow = dynamic(light: "#EEEFF1", dark: "#16161A")
    static let chip = dynamic(light: "#DFE1E5", dark: "#16213A")
    static let pillFill = dynamic(light: "#FAFAFB", dark: "#0F0F11")
    static let pillStroke = dynamic(light: "#D8DBE0", dark: "#26262A")
    /// Raised surfaces on a card or the ground: selected sidebar row, segmented control, file chips.
    static let raised = dynamic(light: "#FFFFFF", dark: "#1A1A1C")
    /// Reply box at the bottom of a conversation.
    static let composerFill = dynamic(light: "#FFFFFF", dark: "#141416")
    static let composerStroke = dynamic(light: "#E4E5E8", dark: "#26262A")
    /// The "code" tile in the list (ink on light, cobalt-tinted on dark).
    static let codeTile = dynamic(light: "#16181D", dark: "#16213A")
    static let onCodeTile = dynamic(light: "#FFFFFF", dark: "#BFD1FF")

    static func card(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#0B0B0C") : .white
    }
    static let cardFill = dynamic(light: "#FFFFFF", dark: "#0B0B0C")
    /// Window ground behind the floating cards when the background is Solid.
    static func ground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#000000") : Color(hex: "#EDEEF0")
    }
    static func sidebar(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#0B0B0C").opacity(0.82) : Color(red: 0.95, green: 0.95, blue: 0.965, opacity: 0.90)
    }
    static func stroke(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.06)
    }
    static func field(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#141416") : Color.black.opacity(0.035)
    }
    static func bubbleIn(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#141416") : Color(hex: "#F2F2F5")
    }

    /// Graphite is the default: near-black in light mode, cobalt in dark mode (Inky).
    static let graphiteHex = "#2B2F38"

    static func accent(_ hex: String) -> Color {
        hex == graphiteHex ? dynamic(light: "#2B2F38", dark: "#7FA6FF") : Color(hex: hex)
    }
    /// Text/icon colour on top of a filled accent shape.
    static func onAccent(_ hex: String) -> Color {
        .white
    }
    /// Fill for primary buttons/bubbles. Graphite in dark mode is a cobalt button with white text.
    static func accentFill(_ hex: String) -> Color {
        hex == graphiteHex ? dynamic(light: "#2B2F38", dark: "#5B8CFF") : Color(hex: hex)
    }
    static func dynamic(light: String, dark: String) -> Color {
        let l = NSColor(Color(hex: light)), d = NSColor(Color(hex: dark))
        return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? d : l })
    }

    static let accentPalette = [graphiteHex, "#0A84FF", "#8E5CF5", "#E64AC0", "#FF375F", "#FF453A", "#FF9F0A", "#FFD60A", "#30D158", "#00C7BE", "#8E8E93"]
}

private struct AccentKey: EnvironmentKey { static let defaultValue: Color = .blue }
private struct OnAccentKey: EnvironmentKey { static let defaultValue: Color = .white }
private struct AccentFillKey: EnvironmentKey { static let defaultValue: Color = .blue }
extension EnvironmentValues {
    var accent: Color {
        get { self[AccentKey.self] }
        set { self[AccentKey.self] = newValue }
    }
    var accentFill: Color {
        get { self[AccentFillKey.self] }
        set { self[AccentFillKey.self] = newValue }
    }
    var onAccent: Color {
        get { self[OnAccentKey.self] }
        set { self[OnAccentKey.self] = newValue }
    }
}

struct Card<Content: View>: View {
    var sidebar = false
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        content
            .background(sidebar ? Theme.sidebar(scheme) : Theme.card(scheme), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(scheme == .dark ? Theme.stroke(scheme) : .clear))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .shadow(color: Color(red: 0.11, green: 0.09, blue: 0.19).opacity(scheme == .dark ? 0.4 : 0.06), radius: 1, y: 1)
            .shadow(color: Color(red: 0.11, green: 0.09, blue: 0.19).opacity(scheme == .dark ? 0.3 : 0.05), radius: 12, y: 8)
    }
}

/// Round icon button used in headers and the composer.
struct CircleIconButton: View {
    var systemImage: String
    var active = false
    var help: String = ""
    var action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accent) private var accent
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? accent : .primary.opacity(0.75))
                .frame(width: 28, height: 28)
                .background(active ? accent.opacity(0.15) : Theme.field(scheme), in: Circle())
                .overlay(Circle().strokeBorder(Theme.stroke(scheme)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Behind-window blur so the desktop shows through ("Glass" / "Clear").
struct VisualEffectBackground: NSViewRepresentable {
    var mode: WindowBackground
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        switch mode {
        case .solid: v.material = .windowBackground; v.alphaValue = 1
        case .glass: v.material = .underWindowBackground; v.alphaValue = 1
        case .clear: v.material = .hudWindow; v.alphaValue = 0.55
        }
    }
}

/// Makes the hosting window borderless-looking: transparent titlebar, content under it, no opaque fill.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { configure(v.window) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { DispatchQueue.main.async { configure(v.window) } }
    private func configure(_ w: NSWindow?) {
        guard let w else { return }
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.styleMask.insert(.fullSizeContentView)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.isMovableByWindowBackground = true
        // An empty unified toolbar makes the titlebar taller, which drops the traffic lights
        // down and in so they sit inside the sidebar card.
        if w.toolbar == nil {
            let t = NSToolbar(identifier: "inkwell.main")
            t.showsBaselineSeparator = false
            t.displayMode = .iconOnly
            w.toolbar = t
        }
        w.toolbarStyle = .unified
        WindowConfigurator.allowFullScreen(w)
    }

    /// SwiftUI keeps resetting this window to "fullScreenNone" (hidden title bar + custom toolbar);
    /// put full screen back whenever it does, so the green button and ⌃⌘F work.
    static func allowFullScreen(_ w: NSWindow) {
        guard w.collectionBehavior.contains(.fullScreenNone) || !w.collectionBehavior.contains(.fullScreenPrimary) else { return }
        w.collectionBehavior.remove(.fullScreenNone)
        w.collectionBehavior.insert(.fullScreenPrimary)
    }
}

/// Account picture: custom image if set, otherwise a monogram in the account colour.
struct AccountAvatar: View {
    var account: Account
    var size: CGFloat = 36
    var body: some View {
        Group {
            if let img = AccountPictures.image(account.id) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Circle().fill(account.color.gradient)
                    Text(String(account.label.prefix(1)).uppercased())
                        .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.black.opacity(0.06)))
    }
}

enum AccountPictures {
    nonisolated(unsafe) private static var cache: [UUID: NSImage] = [:]
    static func url(_ id: UUID) -> URL { Paths.appSupport.appendingPathComponent("account-\(id.uuidString).png") }
    static func image(_ id: UUID) -> NSImage? {
        if let i = cache[id] { return i }
        guard let i = NSImage(contentsOf: url(id)) else { return nil }
        cache[id] = i
        return i
    }
    static func set(_ id: UUID, from source: URL) {
        guard let img = NSImage(contentsOf: source), let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url(id))
        cache[id] = NSImage(data: png)
    }
}

/// Plain button with a soft hover fill (toolbar text buttons).
struct HoverPlainStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { HoverPlainBody(configuration: configuration) }
}
private struct HoverPlainBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hover = false
    var body: some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover || configuration.isPressed ? Theme.fieldFill : .clear))
            .onHover { hover = $0 }
    }
}
