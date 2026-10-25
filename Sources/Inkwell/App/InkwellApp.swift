import SwiftUI
import AppKit

struct InkwellApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Bindable private var store = MailStore.shared

    var body: some Scene {
        Window("Inkwell", id: "main") {
            RootView(store: store)
                .frame(minWidth: 980, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1240, height: 780)
        .commands { AppCommands(store: store) }

        WindowGroup("New Message", id: "compose", for: UUID.self) { $id in
            ComposeView(draftId: id ?? UUID(), store: store)
                .tint(Theme.accent(store.settings.accentHex))
                .environment(\.accent, Theme.accent(store.settings.accentHex))
                .environment(\.onAccent, Theme.onAccent(store.settings.accentHex))
                .environment(\.accentFill, Theme.accentFill(store.settings.accentHex))
        }
        .defaultSize(width: 680, height: 600)

        Settings {
            SettingsView(store: store)
        }
    }
}

struct AppCommands: Commands {
    var store: MailStore
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message") { store.compose() }.keyboardShortcut("n")
            Button("Check for New Mail") { store.syncAll() }.keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .textEditing) {
            Button("Search & Commands…") { store.searchPresented.toggle() }.keyboardShortcut("k")
        }
        CommandMenu("Mailbox") {
            Button("All Inboxes") { store.mailbox = .allInboxes }.keyboardShortcut("1")
            Button("To Reply") { store.mailbox = .toReply }.keyboardShortcut("2")
            Button("Flagged") { store.mailbox = .flagged }.keyboardShortcut("3")
            Button("Snoozed") { store.mailbox = .snoozed }.keyboardShortcut("4")
            Button("Awaiting Reply") { store.mailbox = .reminders }.keyboardShortcut("5")
            Button("Scheduled") { store.mailbox = .scheduled }.keyboardShortcut("6")
            Divider()
            Button("Unread Only") { store.unreadOnly.toggle() }.keyboardShortcut("u", modifiers: [.command, .option])
        }
        CommandMenu("Message") {
            Button("Reply") { store.replyToSelection(all: false) }.keyboardShortcut("r")
            Button("Reply All") { store.replyToSelection(all: true) }.keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Forward") { store.forwardSelection() }.keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button("Archive") { let t = store.currentThreads; Task { await store.archive(t) } }.keyboardShortcut("e", modifiers: [.command])
            Button("Move to Trash") { let t = store.currentThreads; Task { await store.trash(t) } }.keyboardShortcut(.delete, modifiers: .command)
            Button("Toggle Read") { let t = store.currentThreads; Task { await store.toggleRead(t) } }.keyboardShortcut("u", modifiers: [.command, .shift])
            Button("Toggle Flag") { let t = store.currentThreads; Task { await store.toggleFlag(t) } }.keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Snooze Until Tomorrow") { store.snooze(store.currentThreads, until: SnoozeChoice.tomorrow.date) }
            Button("Mute Conversation") { let t = store.currentThreads; Task { await store.mute(t) } }
            Button("Report Spam") { let t = store.currentThreads; Task { await store.reportSpam(t) } }
            Divider()
            Button("Undo") { store.performUndo() }.keyboardShortcut("z", modifiers: [.command, .option])
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Perf.mark("didFinishLaunching")
            let store = MailStore.shared
            applyAppearance(store.settings.appearance)
            // One-time switch to the Graphite theme (solid ground, floating cards).
            if !UserDefaults.standard.bool(forKey: "theme.graphite.v1") {
                UserDefaults.standard.set(true, forKey: "theme.graphite.v1")
                store.settings.accentHex = Theme.graphiteHex
                store.settings.windowBackground = .solid
            }
            Notifier.shared.setup()
            Task {
                await RemoteContentBlocker.prepare()
                // After launch work settles, so it never delays the first frame.
                try? await Task.sleep(for: .milliseconds(300))
                MessageWebView.prewarm()
            }
            store.start()
            installKeyMonitor()
            for n in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.didResizeNotification] {
                NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { note in
                    MainActor.assumeIsolated {
                        if let w = note.object as? NSWindow, w.title == "Inkwell" { WindowConfigurator.allowFullScreen(w) }
                    }
                }
            }
            observeAppearance()
            if let a = ProcessInfo.processInfo.environment["INKWELL_APPEARANCE"] { NSApp.appearance = NSAppearance(named: a == "dark" ? .darkAqua : .aqua) }
            Perf.mark("didFinishLaunching done")
            if let s = ProcessInfo.processInfo.environment["INKWELL_PERF_EXIT"].flatMap(Double.init) {
                DispatchQueue.main.asyncAfter(deadline: .now() + s) { exit(0) }
            }
            if let n = ProcessInfo.processInfo.environment["INKWELL_ARROW_TEST"].flatMap(Int.init) { arrowTest(n) }
            else if let path = ProcessInfo.processInfo.environment["INKWELL_SNAPSHOT"] { debugSnapshot(path) }
            if let path = ProcessInfo.processInfo.environment["INKWELL_STORAGE_SNAPSHOT"] {
                // Debug: render Settings → Storage to a PNG.
                let host = NSHostingView(rootView: StorageSettings(store: store)
                    .environment(\.accentFill, Theme.accentFill(store.settings.accentHex)).frame(width: 720, height: 900))
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
                w.contentView = host; w.orderFrontRegardless()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    }
                    exit(0)
                }
            }
            if let path = ProcessInfo.processInfo.environment["INKWELL_POPUP_SNAPSHOT"] { CodePopup.debugRender(to: path); exit(0) }
            if ProcessInfo.processInfo.environment["INKWELL_POPUP_PREVIEW"] != nil {
                Task { try? await Task.sleep(for: .seconds(1.5)); CodePopup.shared.preview() }
            }
        }
    }

    /// Debug (with INKWELL_SNAPSHOT so nothing syncs, and INKWELL_PERF=1): opens the first
    /// conversation, then presses ↓ `n` times, logging how long each email takes to render.
    @MainActor private func arrowTest(_ n: Int) {
        Task { @MainActor in
            let store = MailStore.shared
            try? await Task.sleep(for: .seconds(3))
            if let t = store.threads.first { store.selection = [t.id] }
            for _ in 0..<n {
                try? await Task.sleep(for: .seconds(1.5))
                print("[open] ---- ↓"); fflush(stdout)
                store.moveSelection(1)
            }
            try? await Task.sleep(for: .seconds(1.5))
            if let path = ProcessInfo.processInfo.environment["INKWELL_ARROW_SHOT"],
               let w = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue == "main" || $0.title == "Inkwell" }),
               let v = w.contentView?.superview ?? w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            exit(0)
        }
    }

    /// Debug: render app windows to PNG files (no screen-recording permission needed).
    @MainActor private func debugSnapshot(_ path: String) {
        Task { @MainActor in
            let store = MailStore.shared
            @MainActor func shot(_ name: String, window title: String = "Inkwell") {
                guard let w = NSApp.windows.first(where: { $0.isVisible && ($0.title == title || (title == "Inkwell" && $0.identifier?.rawValue == "main")) }),
                      let v = w.contentView?.superview ?? w.contentView,
                      let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + "-" + name + ".png"))
            }
            func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
            @MainActor func select(_ match: (ThreadSummary) -> Bool) { if let t = store.threads.first(where: match) { store.selection = [t.id] } }
            let prefix = ProcessInfo.processInfo.environment["INKWELL_SNAPSHOT_PREFIX"] ?? ""
            if ProcessInfo.processInfo.environment["INKWELL_SNAPSHOT_SET"] == "readme" {
                // README images: the inbox, a sign-in code email, and the notch popups.
                store.lastSynced = Date()
                await wait(3); shot(prefix + "inbox")
                select { $0.latest.subject.contains("verification code") && $0.latest.from.name == "Google" }
                await wait(3); shot(prefix + "code-email")
                CodePopup.debugRenderHero(code: true, to: path + "-" + prefix + "popup-code.png")
                CodePopup.debugRenderHero(code: false, to: path + "-" + prefix + "popup-link.png")
                NSApp.terminate(nil); return
            }
            await wait(3); shot(prefix + "1-inbox")
            select { _ in true }
            await wait(3); shot(prefix + "2-chat-thread")
            select { store.account($0.accountId)?.style == .classic || $0.latest.subject.contains("roadmap") }
            await wait(3); shot(prefix + "3-classic-thread")
            select { $0.latest.subject.localizedCaseInsensitiveContains("sale") || $0.latest.subject.contains("code") }
            await wait(3); shot(prefix + "4-newsletter-privacy")
            store.selection = []
            store.searchPresented = true; store.paletteQuery = ProcessInfo.processInfo.environment["INKWELL_SNAPSHOT_QUERY"] ?? "roadmap"
            await wait(2); shot(prefix + "5-search")
            store.searchPresented = false
            store.paletteQuery = ""; store.searchPresented = true
            await wait(2); shot(prefix + "6-command-palette")
            store.searchPresented = false
            store.mailbox = .toReply
            await wait(2); select { _ in true }
            await wait(2); shot(prefix + "7-to-reply")
            store.mailbox = .allInboxes
            store.tab = .updates
            await wait(2); shot(prefix + "8-updates-tab")
            store.tab = .all
            if prefix.isEmpty {
                var d = OutgoingDraft(accountId: store.accounts.first?.id)
                d.fromEmail = store.accounts.first?.email ?? ""
                d.to = "Maya Chen <maya@studio.co>"; d.subject = "Re: Weekend trip?"
                d.plain = "Yes! Count me in. I'll bring the speaker and some snacks.\n\nSee you Saturday,\nSam"
                d.remindAfter = 86400 * 3
                store.compose(d)
                await wait(3); shot("9-compose", window: "Re: Weekend trip?")
                for w in NSApp.windows where w.title == "Re: Weekend trip?" { w.close() }
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                await wait(3)
                if let sw = NSApp.windows.first(where: { $0.isVisible && $0.title != "Inkwell" && $0.frame.width < 900 }) {
                    let v = sw.contentView!.superview!
                    if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                        v.cacheDisplay(in: v.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + "-10-settings.png"))
                    }
                }
            }
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { for w in sender.windows where w.identifier?.rawValue == "main" || w.title == "Inkwell" { w.makeKeyAndOrderFront(nil); return false } }
        return true
    }

    @MainActor private func applyAppearance(_ m: AppearanceMode) {
        NSApp.appearance = m == .light ? NSAppearance(named: .aqua) : m == .dark ? NSAppearance(named: .darkAqua) : nil
    }

    @MainActor private func observeAppearance() {
        withObservationTracking { _ = MailStore.shared.settings.appearance } onChange: {
            Task { @MainActor in
                self.applyAppearance(MailStore.shared.settings.appearance)
                self.observeAppearance()
            }
        }
    }

    /// Single-key shortcuts (Gmail/Vim style) when not typing in a text field.
    @MainActor private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            MainActor.assumeIsolated {
                let store = MailStore.shared
                // ↑ / ↓ in the search palette move its highlight.
                if store.searchPresented, e.keyCode == 125 || e.keyCode == 126,
                   e.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                    NotificationCenter.default.post(name: SearchPalette.moveNotification, object: e.keyCode == 125 ? 1 : -1)
                    return nil
                }
                // ↑ / ↓ move through the message list (unless typing or in the search palette).
                if (e.keyCode == 125 || e.keyCode == 126), !store.searchPresented,
                   e.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                   !(NSApp.keyWindow?.firstResponder is NSText),
                   NSApp.keyWindow?.title == "Inkwell" || NSApp.keyWindow?.identifier?.rawValue == "main" {
                    store.focusedThread = nil
                    store.moveSelection(e.keyCode == 125 ? 1 : -1)
                    return nil
                }
                guard store.settings.vimKeys, !store.searchPresented,
                      e.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return e }
                if NSApp.keyWindow?.firstResponder is NSText { return e }
                guard NSApp.keyWindow?.title == "Inkwell" || NSApp.keyWindow?.identifier?.rawValue == "main" else { return e }
                switch e.charactersIgnoringModifiers ?? "" {
                case "j": store.moveSelection(1)
                case "k": store.moveSelection(-1)
                case "e": let t = store.currentThreads; Task { await store.archive(t) }
                case "#": let t = store.currentThreads; Task { await store.trash(t) }
                case "r": store.replyToSelection(all: false)
                case "a": store.replyToSelection(all: true)
                case "f": store.forwardSelection()
                case "u": let t = store.currentThreads; Task { await store.toggleRead(t) }
                case "s": let t = store.currentThreads; Task { await store.toggleFlag(t) }
                case "h": store.snooze(store.currentThreads, until: SnoozeChoice.tomorrow.date)
                case "m": let t = store.currentThreads; Task { await store.mute(t) }
                case "c": store.compose()
                case "/": store.searchPresented = true
                default: return e
                }
                return nil
            }
        }
    }
}

extension MailStore {
    var currentThreads: [ThreadSummary] {
        if let f = focusedThread { return [f] }
        return selectedThreads
    }

    func moveSelection(_ delta: Int) {
        guard !threads.isEmpty else { return }
        let idx = threads.firstIndex { selection.contains($0.id) }.map { $0 + delta } ?? 0
        let clamped = min(max(idx, 0), threads.count - 1)
        selection = [threads[clamped].id]
    }

    func replyToSelection(all: Bool) {
        guard let t = currentThreads.first else { return }
        let msgs = conversation(t)
        guard let m = msgs.last(where: { !$0.isFromMe }) ?? msgs.last else { return }
        compose(replyDraft(to: m, parsed: db.raw(for: m.id).map(MIME.parse), all: all))
    }

    func forwardSelection() {
        guard let t = currentThreads.first, let m = conversation(t).last else { return }
        compose(forwardDraft(of: m, parsed: db.raw(for: m.id).map(MIME.parse)))
    }
}

