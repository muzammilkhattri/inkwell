import SwiftUI

/// Sidebar from the Graphite design: sits on the window ground, compose button on top,
/// mailbox rows with a raised pill for the selection, accounts, and the "who's signed in" footer.
struct SidebarView: View {
    @Bindable var store: MailStore
    var collapse: () -> Void
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accent) private var accent
    @Environment(\.onAccent) private var onAccent
    @Environment(\.accentFill) private var accentFill
    @Environment(\.colorScheme) private var scheme
    @State private var showSubscriptions = false
    @State private var showSyncing = false
    @AppStorage("expandedAccounts") private var expandedRaw = ""
    private var expanded: Set<String> { Set(expandedRaw.split(separator: ",").map(String.init)) }
    private func toggle(_ id: UUID) {
        var e = expanded; let k = id.uuidString
        if e.contains(k) { e.remove(k) } else { e.insert(k) }
        withAnimation(.snappy) { expandedRaw = e.sorted().joined(separator: ",") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Color.clear.frame(height: 36)   // traffic lights sit here

            Button { store.compose() } label: {
                HStack {
                    Text("New message").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("⌘N").font(.system(size: 11)).opacity(0.7)
                }
                .foregroundStyle(onAccent)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(accentFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    navRow(.allInboxes, "tray", "Inbox", count: store.unreadCounts.values.reduce(0, +))
                    navRow(.toReply, "arrowshape.turn.up.left", "To reply", count: store.toReplyCount)
                    navRow(.flagged, "flag", "Flagged", count: store.flaggedCount)
                    navRow(.snoozed, "clock", "Snoozed", count: store.snoozedCount)
                    navRow(.allRole(.sent), "paperplane", "Sent")
                    navRow(.scheduled, "calendar.badge.clock", "Scheduled")
                    subscriptionsRow

                    Text("ACCOUNTS")
                        .font(.system(size: 11, weight: .semibold)).tracking(0.66)
                        .foregroundStyle(Theme.faint)
                        .padding(.horizontal, 10).padding(.top, 22).padding(.bottom, 6)
                    ForEach(store.accounts) { acct in
                        accountRow(acct)
                        if expanded.contains(acct.id.uuidString) {
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(folderTree(acct)) { n in
                                    folderRow(acct, n)
                                }
                            }
                            .padding(.leading, 18)
                        }
                    }
                    Button { openSettings() } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "plus").font(.system(size: 9, weight: .bold)).frame(width: 8)
                            Text("Add account").font(.system(size: 13))
                            Spacer()
                        }
                        .foregroundStyle(Theme.faint)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 12)
            }
            .scrollIndicators(.never)

            footer
        }
        .padding(.horizontal, 10).padding(.bottom, 12)
    }

    // MARK: rows

    private func isSelected(_ m: Mailbox) -> Bool { store.mailbox == m }

    private func isInAccount(_ id: UUID) -> Bool {
        switch store.mailbox {
        case .accountInbox(let a): return a == id
        case .folder(let a, _): return a == id
        default: return false
        }
    }

    @ViewBuilder private func pill(_ selected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
        if selected {
            shape.fill(Theme.raised).shadow(color: .black.opacity(scheme == .dark ? 0 : 0.08), radius: 1, y: 1)
        } else {
            shape.fill(.clear)
        }
    }

    private func navRow(_ m: Mailbox, _ icon: String, _ title: String, count: Int = 0) -> some View {
        let sel = isSelected(m)
        return HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 13, weight: .regular))
                .foregroundStyle(sel ? Theme.ink : Theme.muted).frame(width: 16)
            Text(title).font(.system(size: 13, weight: sel ? .semibold : .regular)).foregroundStyle(Theme.ink)
            Spacer(minLength: 4)
            if count > 0 {
                Text("\(count)").font(.system(size: 12, weight: sel ? .semibold : .regular)).monospacedDigit()
                    .foregroundStyle(sel ? accent : Theme.muted)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(pill(sel))
        .contentShape(Rectangle())
        .onTapGesture { store.mailbox = m }
        .dropDestination(for: String.self) { ids, _ in handleDrop(ids, onto: m); return true }
    }

    private var subscriptionsRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "newspaper").font(.system(size: 13)).foregroundStyle(Theme.muted).frame(width: 16)
            Text("Subscriptions").font(.system(size: 13)).foregroundStyle(Theme.ink)
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { showSubscriptions = true }
        .popover(isPresented: $showSubscriptions, arrowEdge: .trailing) {
            SubscriptionsSettings(store: store).frame(width: 460, height: 480)
        }
    }

    private func accountRow(_ acct: Account) -> some View {
        let m = Mailbox.accountInbox(acct.id)
        let sel = isSelected(m)
        return HStack(spacing: 10) {
            ZStack {
                if store.accountErrors[acct.id] != nil {
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 9)).foregroundStyle(.orange)
                } else {
                    Circle().fill(acct.color).frame(width: 8, height: 8)
                }
            }
            .frame(width: 16)
            .help(store.accountErrors[acct.id] ?? acct.email)
            Text(acct.label).font(.system(size: 13, weight: sel ? .semibold : .regular)).foregroundStyle(Theme.ink).lineLimit(1)
            Spacer(minLength: 4)
            if let n = store.unreadCounts[acct.id], n > 0 {
                Text("\(n)").font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.muted)
            }
            Button { toggle(acct.id) } label: {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.faint)
                    .rotationEffect(.degrees(expanded.contains(acct.id.uuidString) ? 90 : 0))
                    .frame(width: 16, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(expanded.contains(acct.id.uuidString) ? "Hide folders" : "Show folders")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(pill(sel))
        .contentShape(Rectangle())
        .onTapGesture { store.mailbox = m }
        .draggable("acct:" + acct.id.uuidString) {
            HStack(spacing: 8) { Circle().fill(acct.color).frame(width: 8, height: 8); Text(acct.label).font(.system(size: 13)) }
                .padding(.horizontal, 10).padding(.vertical, 6).background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 8))
        }
        .dropDestination(for: String.self) { ids, _ in
            // Another account dropped here: reorder. Mail dropped here: move it to this inbox.
            if let a = ids.first, a.hasPrefix("acct:"), let from = UUID(uuidString: String(a.dropFirst(5))) {
                moveAccount(from, before: acct.id); return true
            }
            handleDrop(ids, onto: .folder(accountId: acct.id, path: "INBOX")); return true
        }
        .contextMenu {
            Button("Move Up") { shiftAccount(acct.id, by: -1) }.disabled(store.settings.accounts.first?.id == acct.id)
            Button("Move Down") { shiftAccount(acct.id, by: 1) }.disabled(store.settings.accounts.last?.id == acct.id)
            Divider()
            Button("Check for New Mail") { store.sync(accountId: acct.id) }
            if let e = store.accountErrors[acct.id] { Text(e) }
            Button("Account Settings…") { openSettings() }
        }
    }

    private func folderRow(_ acct: Account, _ n: FolderNode) -> some View {
        let m = Mailbox.folder(accountId: acct.id, path: n.folder.path)
        let sel = isSelected(m)
        return HStack(spacing: 8) {
            Image(systemName: icon(n.folder.role)).font(.system(size: 11)).foregroundStyle(Theme.muted).frame(width: 14)
            Text(MUTF7.decode(n.folder.displayName)).font(.system(size: 12.5, weight: sel ? .semibold : .regular)).foregroundStyle(Theme.ink).lineLimit(1)
            Spacer()
        }
        .padding(.leading, 10 + CGFloat(n.depth) * 12).padding(.trailing, 10).padding(.vertical, 5)
        .background(pill(sel))
        .contentShape(Rectangle())
        .onTapGesture { store.mailbox = m }
        .dropDestination(for: String.self) { ids, _ in handleDrop(ids, onto: m); return true }
    }

    // MARK: footer

    private var footer: some View {
        let first = store.accounts.first
        let name = first.map { $0.displayName.isEmpty ? $0.label : $0.displayName } ?? "No account"
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        return HStack(spacing: 10) {
            Text(initials.isEmpty ? "?" : initials).font(.system(size: 11, weight: .semibold)).foregroundStyle(onAccent)
                .frame(width: 26, height: 26).background(accentFill, in: Circle())
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    Text(status(at: ctx.date)).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Button(action: collapse) {
                Image(systemName: "sidebar.left").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Hide sidebar")
        }
        .padding(10)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        // Most syncs (new-mail pushes, the 60 s refresh) finish in well under a second; only say
        // "Syncing…" for ones that take a while, so the footer doesn't flicker on every check.
        .task(id: store.syncing.isEmpty) {
            if store.syncing.isEmpty { showSyncing = false; return }
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled && !store.syncing.isEmpty { showSyncing = true }
        }
    }

    private func status(at now: Date) -> String {
        if showSyncing { return "Syncing…" }
        if !store.accountErrors.isEmpty { return "Can't reach \(store.accountErrors.count == 1 ? "server" : "servers")" }
        if store.accounts.isEmpty { return "Add an account to start" }
        guard let last = store.lastSynced else { return store.syncing.isEmpty ? "Not synced yet" : "Syncing…" }
        let mins = Int(now.timeIntervalSince(last) / 60)
        return mins < 1 ? "Updated just now" : mins < 60 ? "Updated \(mins) min ago" : "Updated \(last.formatted(date: .omitted, time: .shortened))"
    }

    // MARK: folders

    struct FolderNode: Identifiable { var id: String { folder.id }; var folder: MailFolder; var depth: Int }

    private func folderTree(_ acct: Account) -> [FolderNode] {
        let fs = (store.folders[acct.id] ?? []).filter { $0.role != .inbox && $0.selectable }
        let order: [FolderRole] = [.drafts, .sent, .archive, .all, .flagged, .spam, .trash]
        let special = fs.filter { $0.role != .other }.sorted { (order.firstIndex(of: $0.role) ?? 99) < (order.firstIndex(of: $1.role) ?? 99) }
        let others = fs.filter { $0.role == .other }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return special.map { FolderNode(folder: $0, depth: 0) } + others.map {
            FolderNode(folder: $0, depth: max(0, $0.path.components(separatedBy: $0.delimiter.isEmpty ? "/" : $0.delimiter).count - 1))
        }
    }

    private func icon(_ r: FolderRole) -> String {
        switch r {
        case .sent: return "paperplane"; case .drafts: return "doc"; case .trash: return "trash"; case .spam: return "exclamationmark.circle"
        case .archive, .all: return "archivebox"; case .flagged: return "flag"; default: return "folder"
        }
    }

    // MARK: reordering

    private func moveAccount(_ id: UUID, before target: UUID) {
        guard id != target, let from = store.settings.accounts.firstIndex(where: { $0.id == id }),
              let to = store.settings.accounts.firstIndex(where: { $0.id == target }) else { return }
        withAnimation(.snappy) {
            store.settings.accounts.move(fromOffsets: [from], toOffset: from < to ? to + 1 : to)
        }
    }

    private func shiftAccount(_ id: UUID, by delta: Int) {
        guard let i = store.settings.accounts.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard store.settings.accounts.indices.contains(j) else { return }
        withAnimation(.snappy) { store.settings.accounts.swapAt(i, j) }
    }

    private func handleDrop(_ ids: [String], onto m: Mailbox) {
        let threads = store.threads.filter { ids.contains($0.id) }
        guard !threads.isEmpty else { return }
        Task {
            switch m {
            case .folder(let acct, let path): await store.moveThreads(threads.filter { $0.accountId == acct }, to: path)
            case .flagged: await store.setFlag(threads.map(\.latest), true)
            case .snoozed: store.snooze(threads, until: SnoozeChoice.tomorrow.date)
            case .allRole(.trash): await store.trash(threads)
            case .allRole(.spam): await store.reportSpam(threads)
            default: break
            }
        }
    }
}
