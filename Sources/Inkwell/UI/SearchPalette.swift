import SwiftUI

struct PaletteCommand: Identifiable {
    let id = UUID()
    var title: String
    var icon: String
    var shortcut: String = ""
    var run: @MainActor () -> Void
}

/// ⌘K: search every account (local index first, then the servers) and run commands.
struct SearchPalette: View {
    @Bindable var store: MailStore
    var openSettings: () -> Void
    @State private var query = ""
    @State private var local: [MessageRecord] = []
    @State private var remote: [MessageRecord] = []
    @State private var searchingServer = false
    @State private var highlighted = 0
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var focused: Bool
    @State private var keyboardMoved = false
    @State private var lastMouse: NSPoint = .zero

    private var commands: [PaletteCommand] {
        let all: [PaletteCommand] = [
            .init(title: "New Message", icon: "square.and.pencil", shortcut: "⌘N") { store.compose() },
            .init(title: "Go to All Inboxes", icon: "tray.2", shortcut: "G I") { store.mailbox = .allInboxes },
            .init(title: "Go to To Reply", icon: "arrowshape.turn.up.left", shortcut: "G R") { store.mailbox = .toReply },
            .init(title: "Go to Snoozed", icon: "clock", shortcut: "G S") { store.mailbox = .snoozed },
            .init(title: "Go to Flagged", icon: "flag", shortcut: "G F") { store.mailbox = .flagged },
            .init(title: "Go to Scheduled", icon: "paperplane", shortcut: "") { store.mailbox = .scheduled },
            .init(title: "Check for New Mail", icon: "arrow.clockwise", shortcut: "⇧⌘N") { store.syncAll() },
            .init(title: "Toggle Unread Only", icon: "line.3.horizontal.decrease.circle", shortcut: "") { store.unreadOnly.toggle() },
            .init(title: "Appearance: Light", icon: "sun.max", shortcut: "") { store.settings.appearance = .light },
            .init(title: "Appearance: Dark", icon: "moon", shortcut: "") { store.settings.appearance = .dark },
            .init(title: "Appearance: System", icon: "circle.lefthalf.filled", shortcut: "") { store.settings.appearance = .system },
            .init(title: "Archive Selected", icon: "archivebox", shortcut: "E") { let t = store.selectedThreads; Task { await store.archive(t) } },
            .init(title: "Mark All as Read", icon: "envelope.open", shortcut: "") { let t = store.threads; Task { await store.setSeen(store.messages(of: t).filter { !$0.seen }, true) } },
            .init(title: "Open Settings", icon: "gearshape", shortcut: "⌘,") { openSettings() },
        ] + store.accounts.map { a in .init(title: "Go to \(a.label) Inbox", icon: "tray", shortcut: "") { store.mailbox = .accountInbox(a.id) } }
        let q = query.hasPrefix(">") ? String(query.dropFirst()).trimmingCharacters(in: .whitespaces) : query
        if q.isEmpty { return query.hasPrefix(">") || query.isEmpty ? all : [] }
        return all.filter { fuzzy($0.title, q) }
    }

    private var results: [MessageRecord] {
        guard !query.hasPrefix(">") else { return [] }
        var ids = Set(local.map(\.id))
        return local + remote.filter { ids.insert($0.id).inserted }
    }

    @State private var scope: UUID?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accent) private var accent

    private var scoped: [MessageRecord] { scope.map { id in results.filter { $0.accountId == id } } ?? results }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 17)).foregroundStyle(.secondary)
                TextField("Search everything", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 20))
                    .focused($focused)
                    .onSubmit(runHighlighted)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) { store.searchPresented = false; return .handled }
                if searchingServer { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)
            HStack(spacing: 6) {
                chip(scope == nil ? "All accounts" : (store.account(scope!)?.label ?? ""), active: true) {
                    let ids = store.accounts.map(\.id)
                    if let s = scope, let i = ids.firstIndex(of: s) { scope = i + 1 < ids.count ? ids[i + 1] : nil } else { scope = ids.first }
                }
                ForEach(["has:attachment", "is:unread", "from:"], id: \.self) { op in
                    chip(op, active: query.contains(op)) {
                        if !query.contains(op) { query = (query.isEmpty ? "" : query + " ") + op + (op.hasSuffix(":") ? "" : " ") }
                        focused = true
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.bottom, 10)
            if !query.isEmpty || true {
                Divider().opacity(0.5)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            let cmds = Array(commands.prefix(query.isEmpty ? 6 : 6))
                            if !cmds.isEmpty {
                                sectionHeader(query.isEmpty ? "Commands" : "Commands")
                                ForEach(Array(cmds.enumerated()), id: \.element.id) { i, c in
                                    row(index: i) {
                                        Image(systemName: c.icon).frame(width: 24).foregroundStyle(.secondary)
                                        Text(c.title).font(.system(size: 14))
                                        Spacer()
                                        Text(c.shortcut).font(.system(size: 12)).foregroundStyle(.secondary)
                                    } action: { run(c) }
                                    .id(i)
                                }
                            }
                            let res = scoped
                            if !res.isEmpty {
                                sectionHeader("Messages")
                                ForEach(Array(res.prefix(60).enumerated()), id: \.element.id) { j, m in
                                    let i = cmds.count + j
                                    row(index: i) {
                                        AvatarView(address: m.from, size: 30)
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 4) {
                                                Text(m.from.display).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                                Text("· \(m.subject)").font(.system(size: 14)).lineLimit(1)
                                                Spacer()
                                                if !local.contains(where: { $0.id == m.id }) {
                                                    Text("Found on the server · \(store.account(m.accountId)?.label ?? "") \(m.date.formatted(.dateTime.year()))")
                                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                                }
                                            }
                                            Text(highlight(m.snippet)).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    } action: { open(m) }
                                    .id(i)
                                }
                            } else if !query.isEmpty && !query.hasPrefix(">") && !searchingServer && commands.isEmpty {
                                Text("No results").font(.system(size: 14)).foregroundStyle(.secondary).padding(20)
                            }
                        }
                        .padding(8)
                    }
                    .frame(height: rowCount == 0 ? (query.isEmpty ? 0 : 56) : min(380, CGFloat(rowCount) * 52 + 40))
                    .onChange(of: highlighted) { proxy.scrollTo(highlighted) }
                }
            }
            HStack {
                Text("↑↓ navigate   ↵ open   esc close").font(.system(size: 11.5)).foregroundStyle(.secondary)
                Spacer()
                if !query.isEmpty && !query.hasPrefix(">") {
                    Text("\(scoped.count) result\(scoped.count == 1 ? "" : "s") · \(scope == nil ? "every account" : store.account(scope!)?.label ?? "")\(remote.isEmpty ? ", on this Mac" : " + server")")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
        }
        .frame(width: 600)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.stroke(scheme)))
        .shadow(color: .black.opacity(0.22), radius: 30, y: 12)
        .onAppear { query = store.paletteQuery; store.paletteQuery = ""; focusSearchField() }
        .onChange(of: query) { search() }
        // The text field's editor swallows ↑/↓ on macOS, so the app's key monitor forwards them here.
        .onReceive(NotificationCenter.default.publisher(for: SearchPalette.moveNotification)) { n in
            move(n.object as? Int ?? 0)
        }
    }

    private func chip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(active ? accent : .secondary)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(active ? accent.opacity(0.14) : Theme.field(scheme), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Yellow highlight on the words being searched for.
    private func highlight(_ text: String) -> AttributedString {
        var a = AttributedString(text)
        let words = MailStore.parseSearch(query).text.split(separator: " ").map(String.init).filter { $0.count >= 2 }
        for w in words {
            var search = a.startIndex..<a.endIndex
            while let r = a[search].range(of: w, options: .caseInsensitive) {
                a[r].backgroundColor = .yellow.opacity(0.45)
                a[r].foregroundColor = .primary
                search = r.upperBound..<a.endIndex
            }
        }
        return a
    }

    static let moveNotification = Notification.Name("SearchPalette.move")

    private func move(_ delta: Int) {
        keyboardMoved = true; lastMouse = NSEvent.mouseLocation
        highlighted = min(max(highlighted + delta, 0), max(0, rowCount - 1))
    }

    private var rowCount: Int { min(commands.count, 6) + min(scoped.count, 60) }

    private func sectionHeader(_ s: String) -> some View {
        Text(s.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
    }

    private func row<C: View>(index: Int, @ViewBuilder content: () -> C, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) { content() }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(index == highlighted ? accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onContinuousHover { phase in
            // Keyboard scrolling slides rows under a still pointer; only a real mouse move should
            // steal the highlight, or ↑/↓ keeps snapping back to the row under the cursor.
            guard case .active = phase else { return }
            let p = NSEvent.mouseLocation
            if keyboardMoved && p == lastMouse { return }
            keyboardMoved = false; lastMouse = p
            highlighted = index
        }
    }

    private func fuzzy(_ s: String, _ q: String) -> Bool {
        var it = s.lowercased().makeIterator()
        for c in q.lowercased() where c != " " {
            var found = false
            while let n = it.next() { if n == c { found = true; break } }
            if !found { return false }
        }
        return true
    }

    private func search() {
        highlighted = 0
        searchTask?.cancel()
        remote = []
        guard !query.isEmpty, !query.hasPrefix(">") else { local = []; return }
        local = store.localSearch(query)
        let q = query
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, q.count >= 3 else { return }
            searchingServer = true
            let r = await store.serverSearch(q)
            if !Task.isCancelled && q == query { remote = r }
            searchingServer = false
        }
    }

    private func runHighlighted() {
        let cmds = Array(commands.prefix(6))
        if highlighted < cmds.count { run(cmds[highlighted]) }
        else if highlighted - cmds.count < scoped.count { open(scoped[highlighted - cmds.count]) }
    }

    /// Setting focus in onAppear alone is lost on macOS: the field isn't in the window yet, and the
    /// message web view (an AppKit view outside SwiftUI's focus system) keeps first responder.
    private func focusSearchField() {
        Task { @MainActor in
            NSApp.keyWindow?.makeFirstResponder(nil)
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(30))
                if focused { break }
                focused = true
            }
        }
    }

    private func run(_ c: PaletteCommand) { store.searchPresented = false; c.run() }

    private func open(_ m: MessageRecord) {
        store.searchPresented = false
        store.focusedThread = store.thread(for: m)
    }
}
