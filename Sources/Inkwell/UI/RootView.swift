import SwiftUI

struct RootView: View {
    @Bindable var store: MailStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var scheme
    @AppStorage("sidebarHidden") private var sidebarHidden = false
    @AppStorage("listWidth3") private var listWidth: Double = 384

    private var accent: Color { Theme.accent(store.settings.accentHex) }
    private var solid: Bool { store.settings.windowBackground == .solid }

    var body: some View {
        ZStack {
            if solid {
                Theme.ground(scheme).ignoresSafeArea()
            } else {
                VisualEffectBackground(mode: store.settings.windowBackground).ignoresSafeArea()
                // Soft tint so cards read as glass over busy wallpapers.
                LinearGradient(colors: [accent.opacity(scheme == .dark ? 0.05 : 0.12), .purple.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()
            }
            HStack(spacing: Theme.gap) {
                if !sidebarHidden {
                    // On the solid ground the sidebar sits directly on the window; glass modes keep its card.
                    Group {
                        if solid { SidebarView(store: store) { withAnimation(.snappy) { sidebarHidden = true } } }
                        else { Card(sidebar: true) { SidebarView(store: store) { withAnimation(.snappy) { sidebarHidden = true } } } }
                    }
                        .frame(width: 212)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                Card { ThreadListView(store: store, sidebarHidden: sidebarHidden) { withAnimation(.snappy) { sidebarHidden = false } } }
                    .frame(width: listWidth)
                    .overlay(alignment: .trailing) { resizeHandle }
                detail
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .bottom) {
                        if let t = store.toast {
                            ToastView(toast: t) { store.performUndo() }
                                .padding(.bottom, 90)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
            }
            .padding(Theme.gap)
            .animation(.spring(duration: 0.3), value: store.toast)

            if store.searchPresented {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.12).ignoresSafeArea().onTapGesture { store.searchPresented = false }
                    SearchPalette(store: store, openSettings: { openSettings() }).padding(.top, 60)
                }
            }
        }
        .ignoresSafeArea()
        .background(WindowConfigurator())
        .environment(\.accent, accent)
        .environment(\.onAccent, Theme.onAccent(store.settings.accentHex))
        .environment(\.accentFill, Theme.accentFill(store.settings.accentHex))
        .tint(accent)
        .sheet(item: $store.pendingApproval) { p in SendApprovalView(store: store, approval: p) }
        .onAppear { store.openCompose = { id in openWindow(id: "compose", value: id) } }
    }

    private var resizeHandle: some View {
        Color.clear.frame(width: 8).contentShape(Rectangle())
            .offset(x: Theme.gap / 2 + 4)
            .onHover { if $0 { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture().onChanged { v in listWidth = min(520, max(300, listWidth + v.translation.width)) })
    }

    @ViewBuilder private var detail: some View {
        if let t = store.focusedThread ?? (store.selection.count == 1 ? store.selectedThreads.first : nil) {
            ConversationView(thread: t, store: store).id(t.id)
        } else {
            VStack(spacing: Theme.gap) {
                Card {
                    Group {
                        if store.selection.count > 1 {
                            let ts = store.selectedThreads
                            VStack(spacing: 14) {
                                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 40)).foregroundStyle(.tertiary)
                                Text("\(ts.count) conversations selected").font(.title3)
                                HStack {
                                    Button("Archive") { Task { await store.archive(ts) } }
                                    Button("Trash") { Task { await store.trash(ts) } }
                                    Button(ts.contains(where: \.unread) ? "Mark Read" : "Mark Unread") { Task { await store.toggleRead(ts) } }
                                    Menu("Snooze") { SnoozeMenu { store.snooze(ts, until: $0) } }.fixedSize()
                                }
                            }
                        } else {
                            VStack(spacing: 10) {
                                Image(systemName: "tray").font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
                                Text("No conversation selected").font(.system(size: 14)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Card {
                    HStack {
                        Text("Reply…").font(.system(size: 13.5)).foregroundStyle(.tertiary)
                        Spacer()
                        ForEach(["paperclip", "textformat", "clock"], id: \.self) { i in
                            Image(systemName: i).font(.system(size: 12)).foregroundStyle(.tertiary)
                                .frame(width: 28, height: 28).background(Theme.field(scheme), in: Circle())
                        }
                        Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.onAccent(store.settings.accentHex))
                            .frame(width: 28, height: 28).background(Theme.accentFill(store.settings.accentHex).opacity(0.4), in: Circle())
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
        }
    }
}

/// Shown when an AI app (via MCP) asks to send a draft.
struct SendApprovalView: View {
    var store: MailStore
    var approval: PendingSendApproval

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("\(approval.app) wants to send an email", systemImage: "sparkles").font(.headline)
            Grid(alignment: .leading, verticalSpacing: 6) {
                GridRow { Text("From").foregroundStyle(.secondary); Text(approval.draft.fromEmail) }
                GridRow { Text("To").foregroundStyle(.secondary); Text(approval.draft.to) }
                if !approval.draft.cc.isEmpty { GridRow { Text("Cc").foregroundStyle(.secondary); Text(approval.draft.cc) } }
                GridRow { Text("Subject").foregroundStyle(.secondary); Text(approval.draft.subject) }
            }
            ScrollView { Text(approval.draft.plain).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                .frame(height: 180).padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Trust these recipients for this session") { store.approvePendingSend(trustRecipients: true, edit: false) }
                Spacer()
                Button("Don't Send") { store.rejectPendingSend() }.keyboardShortcut(.cancelAction)
                Button("Edit in Inkwell") { store.approvePendingSend(trustRecipients: false, edit: true) }
                Button("Send") { store.approvePendingSend(trustRecipients: false, edit: false) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
