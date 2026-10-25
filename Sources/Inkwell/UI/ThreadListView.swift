import SwiftUI

struct ThreadListView: View {
    @Bindable var store: MailStore
    var sidebarHidden: Bool
    var showSidebar: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accent) private var accent
    @State private var customSnooze: [ThreadSummary]?
    @State private var hovered: String?

    private var showTabs: Bool {
        switch store.mailbox { case .allInboxes, .accountInbox: return true; default: return false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if showTabs { tabs }
            if case .scheduled = store.mailbox {
                ScheduledList(store: store)
            } else if store.threads.isEmpty && store.unreadOnly && !store.syncing.isEmpty {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Loading unread mail…").font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.threads.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: emptyIcon, description: Text(emptySubtitle))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(store.threads) { t in
                                ThreadRow(thread: t, account: store.account(t.accountId), selected: store.selection.contains(t.id), store: store)
                                    .id(t.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { select(t) }
                                    .draggable(t.id)
                                    .contextMenu { contextMenu(for: menuTargets(t)) }
                            }
                            .onAppear { Perf.mark("thread rows built"); DispatchQueue.main.async { Perf.mark("first list frame") } }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                    }
                    .scrollIndicators(.automatic)
                    .onChange(of: store.selection) { if let s = store.selection.first { withAnimation { proxy.scrollTo(s) } } }
                }
            }
        }
        .sheet(item: Binding(get: { customSnooze.map { IdentifiedThreads(threads: $0) } }, set: { customSnooze = $0?.threads })) { item in
            DatePickerSheet(title: "Snooze until…", action: "Snooze") { store.snooze(item.threads, until: $0) }
        }
    }

    // ⌘/⇧ click for multi-select
    private func select(_ t: ThreadSummary) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if store.selection.contains(t.id) { store.selection.remove(t.id) } else { store.selection.insert(t.id) }
        } else if mods.contains(.shift), let anchor = store.threads.firstIndex(where: { store.selection.contains($0.id) }),
                  let idx = store.threads.firstIndex(where: { $0.id == t.id }) {
            store.selection = Set(store.threads[min(anchor, idx)...max(anchor, idx)].map(\.id))
        } else {
            store.selection = [t.id]
        }
    }

    private func menuTargets(_ t: ThreadSummary) -> [ThreadSummary] {
        store.selection.contains(t.id) ? store.selectedThreads : [t]
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            if sidebarHidden {
                // With the sidebar hidden the window buttons sit over this card: reserve their space
                // and put the "show sidebar" button right after them.
                HStack(spacing: 10) {
                    Color.clear.frame(width: 58, height: 14)
                    Button(action: showSidebar) {
                        Image(systemName: "sidebar.left").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
                            .frame(width: 26, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("Show sidebar")
                    Spacer()
                }
                .frame(height: 20)
                .padding(.top, -8).padding(.bottom, -6)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(titleText).font(.system(size: 22, weight: .bold)).tracking(-0.44).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: 8)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Button { store.searchPresented = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium))
                    Text("Search or ask anything").font(.system(size: 13))
                    Spacer()
                    Text("⌘K").font(.system(size: 11))
                }
                .foregroundStyle(Theme.faint)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Theme.fieldFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.top, sidebarHidden ? 14 : 20).padding(.bottom, showTabs ? 14 : 10)
    }

    private var titleText: String {
        switch store.mailbox {
        case .allInboxes: return "Inbox"
        case .accountInbox(let id): return store.account(id)?.label ?? "Inbox"
        case .folder(let id, _): return "\(store.account(id)?.label ?? "") › \(store.mailbox.title)"
        case .allRole: return "All inboxes › \(store.mailbox.title)"
        default: return store.mailbox.title
        }
    }

    private var subtitle: String {
        let unread = store.threads.filter(\.unread).count
        switch store.mailbox {
        default:
            return unread > 0 ? "\(unread) unread" : ""
        }
    }

    /// Underlined text tabs with a hairline under the whole row.
    private var tabs: some View {
        HStack(spacing: 18) {
            ForEach(InboxTab.allCases) { t in
                let sel = store.tab == t
                Button { store.tab = t } label: {
                    HStack(spacing: 0) {
                        Text(t.rawValue)
                        if let n = store.tabUnread[t], n > 0, t != .all { Text(" · \(n)").monospacedDigit() }
                    }
                    .font(.system(size: 13, weight: sel ? .semibold : .regular))
                    .foregroundStyle(sel ? Theme.ink : Theme.muted)
                    .lineLimit(1).fixedSize()
                    .padding(.bottom, 9)
                    .overlay(alignment: .bottom) { if sel { Rectangle().fill(Theme.ink).frame(height: 2) } }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            Button { store.unreadOnly.toggle() } label: {
                Text("Unread").font(.system(size: 12, weight: store.unreadOnly ? .semibold : .regular))
                    .foregroundStyle(store.unreadOnly ? Theme.ink : Theme.faint)
                    .padding(.bottom, 9).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Show unread only")
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .padding(.horizontal, 20).padding(.bottom, 6)
    }

    private var emptyTitle: String {
        switch store.mailbox { case .toReply: return "Nothing waiting on you"; case .snoozed: return "No snoozed mail"; default: return store.settings.accounts.isEmpty ? "No accounts yet" : store.unreadOnly ? "No unread mail" : "All caught up" }
    }
    private var emptyIcon: String { store.settings.accounts.isEmpty ? "person.crop.circle.badge.plus" : "checkmark.circle" }
    private var emptySubtitle: String { store.settings.accounts.isEmpty ? "Click “Add account” to connect Gmail, iCloud, Outlook, Yahoo, Fastmail or any IMAP account." : "" }

    @ViewBuilder
    private func contextMenu(for ts: [ThreadSummary]) -> some View {
        if !ts.isEmpty {
            Button("Archive") { Task { await store.archive(ts) } }
            Button("Move to Trash") { Task { await store.trash(ts) } }
            Divider()
            Button(ts.contains(where: \.unread) ? "Mark as Read" : "Mark as Unread") { Task { await store.toggleRead(ts) } }
            Button(ts.contains(where: \.flagged) ? "Unflag" : "Flag") { Task { await store.toggleFlag(ts) } }
            Menu("Snooze") {
                SnoozeMenu { d in store.snooze(ts, until: d) }
                Divider()
                Button("Pick Date & Time…") { customSnooze = ts }
            }
            if case .snoozed = store.mailbox { Button("Unsnooze") { store.unsnooze(ts) } }
            Menu("Move to") {
                ForEach(store.folders[ts[0].accountId]?.filter(\.selectable) ?? []) { f in
                    Button(MUTF7.decode(f.path)) { Task { await store.moveThreads(ts.filter { $0.accountId == f.accountId }, to: f.path) } }
                }
            }
            Divider()
            Button("Mute Conversation") { Task { await store.mute(ts) } }
            if ts.count == 1 {
                if !ts[0].latest.listUnsubscribe.isEmpty { Button("Unsubscribe") { Task { await store.unsubscribe(ts[0].latest) } } }
                Button("Block \(ts[0].latest.from.email)") { Task { await store.blockSender(ts[0].latest.from.email) } }
            }
            Button("Report Spam") { Task { await store.reportSpam(ts) } }
        }
    }
}

struct IdentifiedThreads: Identifiable { let id = UUID(); var threads: [ThreadSummary] }

struct ThreadRow: View {
    var thread: ThreadSummary
    var account: Account?
    var selected: Bool
    var store: MailStore
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    private var counterpart: EmailAddress {
        let m = thread.latest
        if m.isFromMe { return m.to.first ?? m.from }
        return thread.messages.first(where: { !$0.isFromMe })?.from ?? m.from
    }

    private var code: String? {
        let m = thread.latest
        guard m.category != .promos else { return nil }
        return Classifier.oneTimeCode(subject: m.subject, text: m.snippet)
    }

    var body: some View {
        let m = thread.latest
        let unread = thread.unread
        HStack(alignment: .top, spacing: 12) {
            AvatarView(address: counterpart, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(m.isFromMe ? "To: \(counterpart.display)" : counterpart.display)
                        .font(.system(size: 13.5, weight: unread ? .semibold : .medium))
                        .foregroundStyle(unread ? Theme.ink : Theme.ink2)
                        .lineLimit(1)
                    if thread.count > 1 { Text("\(thread.count)").font(.system(size: 11.5)).foregroundStyle(Theme.faint) }
                    Spacer(minLength: 4)
                    Text(m.date.listLabel).font(.system(size: 11.5, weight: unread ? .semibold : .regular))
                        .foregroundStyle(unread ? accent : Theme.faint)
                }
                HStack(spacing: 5) {
                    if thread.flagged { Image(systemName: "flag.fill").font(.system(size: 10)).foregroundStyle(.orange) }
                    Text(m.subject.isEmpty ? "(no subject)" : m.subject)
                        .font(.system(size: 13, weight: unread ? .semibold : .regular))
                        .foregroundStyle(unread ? Theme.ink : Theme.ink2)
                        .lineLimit(1)
                }
                if code == nil {
                    Text(m.snippet).font(.system(size: 12.5)).foregroundStyle(unread ? Theme.muted : Theme.faint).lineLimit(1)
                }
                chips
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: selected ? 14 : 10, style: .continuous)
                .fill(selected ? Theme.selectedRow : hovering ? Theme.selectedRow.opacity(0.5) : .clear)
        )
        .overlay(alignment: .topLeading) {
            if unread { Circle().fill(accent).frame(width: 6, height: 6).offset(x: 2, y: 26) }
        }
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var chips: some View {
        let latestIn = thread.messages.first(where: { !$0.isFromMe })
        let needsReply = latestIn.map { $0.needsReply && !$0.answered } ?? false
        let files = thread.latest.attachmentNames.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let code {
            let copied = store.copiedCodes.contains(code)
            HStack(spacing: 8) {
                Text(Self.grouped(code)).font(.system(size: 15, weight: .semibold).monospacedDigit()).tracking(1.8)
                    .foregroundStyle(Theme.onCodeTile)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Theme.codeTile, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string)
                    Sounds.play(.copy)
                    store.copiedCodes.insert(code)
                } label: {
                    Text(copied ? "Copied" : "Copy").font(.system(size: 12, weight: .semibold)).foregroundStyle(accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 6)
        } else if needsReply || !files.isEmpty {
            HStack(spacing: 6) {
                if needsReply {
                    Text("Needs reply").font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                ForEach(files.prefix(2), id: \.self) { f in
                    Text(f).font(.system(size: 11)).foregroundStyle(Theme.ink).lineLimit(1)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.hairline))
                }
                if files.count > 2 { Text("+\(files.count - 2)").font(.system(size: 11)).foregroundStyle(Theme.faint) }
            }
            .padding(.top, 6)
        }
    }

    /// "482913" → "482 913".
    static func grouped(_ code: String) -> String {
        guard code.allSatisfy(\.isNumber), code.count == 6 || code.count == 8 else { return code }
        let mid = code.index(code.startIndex, offsetBy: code.count / 2)
        return code[..<mid] + " " + code[mid...]
    }
}

struct ScheduledList: View {
    var store: MailStore
    @State private var items: [OutgoingDraft] = []
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(items) { d in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("To: \(d.to)").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                            Spacer()
                            if let at = d.sendAt { Text(at.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 13)).foregroundStyle(.secondary) }
                        }
                        Text(d.subject).font(.system(size: 14)).lineLimit(1)
                        Text(d.plain).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .padding(12)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button("Edit / Cancel Schedule") { store.cancelScheduled(d); items = store.scheduledDrafts() }
                        Button("Send Now") {
                            store.db.exec("DELETE FROM scheduled WHERE id=?", [d.id.uuidString])
                            var c = d; c.sendAt = nil; store.queueSend(c); items = store.scheduledDrafts()
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
        }
        .overlay { if items.isEmpty { ContentUnavailableView("Nothing scheduled", systemImage: "paperplane", description: Text("Use Send Later in the composer.")) } }
        .onAppear { items = store.scheduledDrafts() }
    }
}
