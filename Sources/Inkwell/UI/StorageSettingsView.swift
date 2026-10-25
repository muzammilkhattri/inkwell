import SwiftUI
import AppKit

/// Settings → Storage: what Inkwell keeps on this Mac, and freeing it up.
struct StorageSettings: View {
    @Bindable var store: MailStore
    @Environment(\.accentFill) private var accentFill
    @State private var report: StorageManager.Report?
    @State private var estimate: (emails: Int, bytes: Int64)?
    @State private var accountFilter: UUID?          // nil = all accounts
    @State private var confirming = false
    @State private var working: String?
    @State private var lastResult: String?

    private static let segBodies = Theme.dynamic(light: "#2B2F38", dark: "#5B8CFF")
    private static let segIndex = Theme.dynamic(light: "#6B6E76", dark: "#9A9AA1")
    private static let segList = Theme.dynamic(light: "#A7AAB1", dark: "#5E5E66")
    private static let segOther = Theme.dynamic(light: "#D3D5DA", dark: "#3A3A41")

    private var options: StorageManager.Options {
        var o = store.storageOptions
        o.accountIds = accountFilter.map { [$0] } ?? []
        return o
    }
    private var allAccountIds: [UUID] { store.settings.accounts.map(\.id) }

    static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter(); f.countStyle = .file; f.allowedUnits = [.useKB, .useMB, .useGB]
        return f.string(fromByteCount: n)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                summary.padding(.bottom, 26)
                byAccount.padding(.bottom, 16)
                cleanUpCard.padding(.bottom, 18)
                footer
            }
            .padding(.horizontal, 36).padding(.top, 26).padding(.bottom, 28)
        }
        .task { await refresh() }
        .task(id: options) { await refreshEstimate() }
        .alert(confirmTitle, isPresented: $confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Clean Up", role: .destructive) { Task { await cleanUp() } }
        } message: {
            Text(store.settings.storageEntireEmails
                 ? "These emails disappear from Inkwell on this Mac. They stay on your mail server."
                 : "The emails stay in your list. Their contents download again from your mail server when you open them.")
        }
    }

    private var confirmTitle: String {
        "Remove \(estimate?.emails ?? 0) downloaded email\(estimate?.emails == 1 ? "" : "s") from this Mac?"
    }

    // MARK: sections

    private var summary: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    sectionLabel("ON THIS MAC")
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(report.map { Self.bytes($0.total) } ?? "—")
                            .font(.system(size: 34, weight: .bold)).tracking(-0.6).foregroundStyle(Theme.ink)
                            .contentTransition(.numericText())
                        if let r = report {
                            Text("· \(r.emails) emails · \(r.downloaded) downloaded").font(.system(size: 13)).foregroundStyle(Theme.muted)
                        }
                    }
                }
                Spacer()
                Text("Mail on your server isn’t counted").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            bar
            HStack(spacing: 22) {
                legend("Emails & attachments", report?.bodies, Self.segBodies)
                legend("Search index", report?.index, Self.segIndex)
                legend("Mail list", report?.list, Self.segList)
                legend("Other", report?.other, Self.segOther)
            }
        }
    }

    private var bar: some View {
        GeometryReader { g in
            let r = report ?? StorageManager.Report()
            let parts: [(Int64, Color)] = [(r.bodies, Self.segBodies), (r.index, Self.segIndex), (r.list, Self.segList), (r.other, Self.segOther)]
            let total = max(1, Double(r.total))
            let gaps = CGFloat(parts.filter { $0.0 > 0 }.count - 1) * 2
            HStack(spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                    if p.0 > 0 { Rectangle().fill(p.1).frame(width: max(2, (g.size.width - max(0, gaps)) * CGFloat(Double(p.0) / total))) }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 10)
        .background(Theme.fieldFill)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .animation(.snappy, value: report?.total)
    }

    private func legend(_ title: String, _ value: Int64?, _ color: Color) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.ink2)
            Text(value.map(Self.bytes) ?? "—").font(.system(size: 12)).foregroundStyle(Theme.muted).monospacedDigit()
        }
    }

    private var byAccount: some View {
        VStack(spacing: 0) {
            HStack {
                sectionLabel("BY ACCOUNT").frame(maxWidth: .infinity, alignment: .leading)
                sectionLabel("EMAILS").frame(width: 90, alignment: .trailing)
                sectionLabel("OLDEST").frame(width: 90, alignment: .trailing)
                sectionLabel("SIZE").frame(width: 90, alignment: .trailing)
            }
            .padding(.bottom, 8)
            Divider().overlay(Theme.hairline)
            let rows = report?.accounts ?? []
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, u in
                let a = store.account(u.id)
                HStack {
                    HStack(spacing: 10) {
                        Circle().fill(a?.color ?? .gray).frame(width: 9, height: 9)
                        Text(a?.label ?? "Account").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                        Text(a?.email ?? "").font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(u.emails)").frame(width: 90, alignment: .trailing).foregroundStyle(Theme.ink2)
                    Text(u.oldest.map { $0.formatted(.dateTime.month(.abbreviated).year()) } ?? "—").frame(width: 90, alignment: .trailing).foregroundStyle(Theme.ink2)
                    Text(Self.bytes(u.bytes)).fontWeight(.medium).frame(width: 90, alignment: .trailing).foregroundStyle(Theme.ink)
                }
                .font(.system(size: 13)).monospacedDigit()
                .padding(.vertical, 11)
                if i < rows.count - 1 { Divider().overlay(Theme.hairline.opacity(0.6)) }
            }
        }
    }

    private var cleanUpCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Free up space").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                Text("Removes downloaded copies from this Mac only. Every email stays on your mail server and downloads again when you open it.")
                    .font(.system(size: 13)).lineSpacing(3).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Text("Remove emails older than").font(.system(size: 13)).foregroundStyle(Theme.ink)
                Picker("", selection: $store.settings.storageMonths) {
                    Text("1 month").tag(1); Text("3 months").tag(3); Text("6 months").tag(6)
                    Text("1 year").tag(12); Text("2 years").tag(24)
                }
                .labelsHidden().fixedSize()
                Text("from").font(.system(size: 13)).foregroundStyle(Theme.muted)
                Picker("", selection: $accountFilter) {
                    Text("All accounts").tag(UUID?.none)
                    ForEach(store.settings.accounts) { a in Text(a.label).tag(UUID?.some(a.id)) }
                }
                .labelsHidden().fixedSize()
            }
            VStack(alignment: .leading, spacing: 9) {
                radio(!store.settings.storageEntireEmails, "Bodies and attachments only", "Emails stay in your list and search by subject and sender") {
                    store.settings.storageEntireEmails = false
                }
                radio(store.settings.storageEntireEmails, "Entire emails", "Also removed from the list and local search. Unread emails are kept") {
                    store.settings.storageEntireEmails = true
                }
                Toggle("Keep flagged and snoozed emails", isOn: $store.settings.storageKeepImportant)
                    .toggleStyle(.checkbox).font(.system(size: 13)).padding(.top, 3)
            }
            Divider().overlay(Theme.hairline)
            HStack(alignment: .center) {
                if let working {
                    ProgressView().controlSize(.small)
                    Text(working).font(.system(size: 13)).foregroundStyle(Theme.ink2)
                } else if let e = estimate, e.emails > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Frees about").font(.system(size: 13)).foregroundStyle(Theme.ink2)
                        Text(Self.bytes(e.bytes)).font(.system(size: 17, weight: .bold)).tracking(-0.2).foregroundStyle(Theme.ink)
                        Text("from \(e.emails) email\(e.emails == 1 ? "" : "s")").font(.system(size: 13)).foregroundStyle(Theme.muted)
                    }
                } else {
                    Text(lastResult ?? (estimate == nil ? "Calculating…" : "Nothing to clean up with these settings"))
                        .font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button { confirming = true } label: {
                    Text("Clean Up…").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(accentFill, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(working != nil || (estimate?.emails ?? 0) == 0)
                .opacity(working != nil || (estimate?.emails ?? 0) == 0 ? 0.45 : 1)
            }
            .padding(.top, 0)
        }
        .padding(.horizontal, 22).padding(.vertical, 20)
        .background(Theme.fieldFill, in: RoundedRectangle(cornerRadius: 14))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clean up automatically").font(.system(size: 13)).foregroundStyle(Theme.ink)
                    Text("Once a day, using the settings above").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Toggle("", isOn: $store.settings.storageAutoClean).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            Divider().overlay(Theme.hairline)
            HStack(spacing: 18) {
                link("Optimize search index") {
                    await run("Optimizing…") { db in StorageManager.compact(db: db) }
                }
                link("Clear image cache · \(Self.bytes(report?.imageCache ?? 0))") {
                    StorageManager.clearImageCache()
                    await refresh()
                }
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.database]) }
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
        }
    }

    // MARK: pieces

    private func sectionLabel(_ s: String) -> some View {
        Text(s).font(.system(size: 11, weight: .semibold)).tracking(0.66).foregroundStyle(Theme.muted)
    }

    private func radio(_ on: Bool, _ title: String, _ detail: String, _ select: @escaping () -> Void) -> some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 9) {
                ZStack {
                    Circle().fill(on ? accentFill : Theme.cardFill)
                    Circle().strokeBorder(on ? Color.clear : Theme.pillStroke, lineWidth: 1)
                    if on { Circle().fill(.white).frame(width: 6, height: 6) }
                }
                .frame(width: 16, height: 16).padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13)).foregroundStyle(Theme.ink)
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func link(_ title: String, _ action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink2)
        }
        .buttonStyle(.plain)
        .disabled(working != nil)
    }

    // MARK: work (all off the main thread)

    private func refresh() async {
        let (db, ids) = (store.db, store.accounts.map(\.id))
        report = await Task.detached(priority: .userInitiated) { StorageManager.report(db: db, accountIds: ids) }.value
    }

    private func refreshEstimate() async {
        let (db, o, all) = (store.db, options, allAccountIds)
        try? await Task.sleep(for: .milliseconds(120))  // settle while pickers change
        guard !Task.isCancelled else { return }
        estimate = await Task.detached(priority: .userInitiated) { StorageManager.estimate(db: db, o, allAccounts: all) }.value
    }

    private func run(_ label: String, _ work: @escaping @Sendable (Database) -> Void) async {
        working = label
        let db = store.db
        await Task.detached(priority: .userInitiated) { work(db) }.value
        working = nil
        await refresh()
    }

    private func cleanUp() async {
        working = "Cleaning up…"
        lastResult = nil
        let (db, o, all) = (store.db, options, allAccountIds)
        let r = await Task.detached(priority: .userInitiated) { StorageManager.cleanUp(db: db, o, allAccounts: all) }.value
        working = nil
        lastResult = "Removed \(r.emails) email\(r.emails == 1 ? "" : "s") · freed \(Self.bytes(r.freed))"
        store.reload()
        await refresh()
        await refreshEstimate()
    }
}
