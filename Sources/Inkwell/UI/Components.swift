import SwiftUI
import AppKit
import Contacts

// MARK: Avatar (Contacts photo → brand icon → initials)

@MainActor
final class AvatarCache {
    static let shared = AvatarCache()
    private var images: [String: NSImage] = [:]
    private var misses = Set<String>()
    private var inflight = Set<String>()
    private static let personalDomains: Set<String> = ["gmail.com", "googlemail.com", "icloud.com", "me.com", "mac.com", "outlook.com", "hotmail.com", "live.com", "yahoo.com", "aol.com", "proton.me", "protonmail.com", "fastmail.com", "gmx.com", "gmx.de", "hey.com", "msn.com", "yandex.com", "zoho.com"]

    func cached(_ email: String) -> NSImage? { images[email.lowercased()] ?? images["@" + (email.split(separator: "@").last.map(String.init) ?? "")] }

    func load(_ email: String, brandIcons: Bool) async -> NSImage? {
        let e = email.lowercased()
        if let i = cached(e) { return i }
        if misses.contains(e) || inflight.contains(e) { return nil }
        inflight.insert(e); defer { inflight.remove(e) }
        if let img = contactPhoto(e) { images[e] = img; return img }
        let domain = e.split(separator: "@").last.map(String.init) ?? ""
        guard brandIcons, !domain.isEmpty, !AvatarCache.personalDomains.contains(domain) else { misses.insert(e); return nil }
        if misses.contains("@" + domain) { misses.insert(e); return nil }
        // Root domain (mail.example.com → example.com) and the site's own icon.
        let parts = domain.split(separator: ".")
        let root = parts.count > 2 ? parts.suffix(2).joined(separator: ".") : domain
        for path in ["https://\(root)/apple-touch-icon.png", "https://\(root)/favicon.ico"] {
            guard let url = URL(string: path) else { continue }
            var req = URLRequest(url: url); req.timeoutInterval = 6
            if let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
               let img = NSImage(data: data), img.size.width >= 16 {
                images["@" + domain] = img
                return img
            }
        }
        misses.insert("@" + domain); misses.insert(e)
        return nil
    }

    private func contactPhoto(_ email: String) -> NSImage? {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return nil }
        let pred = CNContact.predicateForContacts(matchingEmailAddress: email)
        let keys = [CNContactThumbnailImageDataKey as CNKeyDescriptor]
        guard let c = try? CNContactStore().unifiedContacts(matching: pred, keysToFetch: keys).first, let d = c.thumbnailImageData else { return nil }
        return NSImage(data: d)
    }
}

struct AvatarView: View {
    var address: EmailAddress
    var size: CGFloat = 34
    var fallbackColor: Color = .accentColor
    var ring: Color? = nil
    @State private var image: NSImage?
    @Environment(\.colorScheme) private var scheme

    var initials: String {
        let src = address.name.isEmpty ? address.email : address.name
        let parts = src.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" }).prefix(2)
        return parts.compactMap(\.first).map(String.init).joined().uppercased()
    }

    /// Soft tile + darker initials, from the design's pastel set.
    private static let pastels: [(bg: String, fg: String)] = [
        ("#D8C4E8", "#5B3A78"), ("#F2DCC8", "#8A4B1C"), ("#CFE0EC", "#2E5873"), ("#E6E2D6", "#5E5640"),
        ("#F0D6D6", "#7A3434"), ("#D6DCEC", "#3B4A73"), ("#EAD6E6", "#6E3563"), ("#DDE3E8", "#3E4A55"),
    ]
    private var pastel: (bg: String, fg: String) {
        Self.pastels[Self.pastelIndex(address.email)]
    }
    /// Unsigned: a signed hash can land on Int.min, and abs(Int.min) traps.
    nonisolated static func pastelIndex(_ email: String) -> Int {
        let h = email.lowercased().unicodeScalars.reduce(UInt(0)) { ($0 &* 31) &+ UInt($1.value) }
        return Int(h % 8)
    }
    var color: Color { Color(hex: pastel.fg) }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .background(Color.white)
            } else {
                // Dark mode flips the pair: deep tinted tile, pastel initials.
                Circle().fill(scheme == .dark ? Color(hex: pastel.fg).opacity(0.45) : Color(hex: pastel.bg))
                Text(initials).font(.system(size: size * 0.35, weight: .semibold)).foregroundStyle(Color(hex: scheme == .dark ? pastel.bg : pastel.fg))
            }
        }
        .frame(width: ring == nil ? size : size - 7, height: ring == nil ? size : size - 7)
        .clipShape(Circle())
        .padding(ring == nil ? 0 : 3.5)
        .overlay { if let ring { Circle().strokeBorder(ring, lineWidth: 2) } }
        .task(id: address.email) {
            image = AvatarCache.shared.cached(address.email)
            if image == nil { image = await AvatarCache.shared.load(address.email, brandIcons: MailStore.shared.settings.showBrandIcons) }
        }
    }
}

// MARK: Snooze choices

enum SnoozeChoice: CaseIterable, Identifiable {
    case laterToday, thisEvening, tomorrow, friday, weekend, nextWeek
    var id: Self { self }

    var label: String {
        switch self {
        case .laterToday: return "Later Today"
        case .thisEvening: return "This Evening"
        case .tomorrow: return "Tomorrow"
        case .friday: return "Friday"
        case .weekend: return "This Weekend"
        case .nextWeek: return "Next Week"
        }
    }

    var date: Date {
        let cal = Calendar.current
        let now = Date()
        func at(_ day: Date, _ hour: Int) -> Date { cal.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day }
        func next(weekday: Int) -> Date {
            cal.nextDate(after: now, matching: DateComponents(weekday: weekday), matchingPolicy: .nextTime) ?? now.addingTimeInterval(86400)
        }
        switch self {
        case .laterToday: return now.addingTimeInterval(3 * 3600)
        case .thisEvening:
            let e = at(now, 18); return e > now ? e : at(cal.date(byAdding: .day, value: 1, to: now)!, 18)
        case .tomorrow: return at(cal.date(byAdding: .day, value: 1, to: now)!, 8)
        case .friday: return at(next(weekday: 6), 8)
        case .weekend: return at(next(weekday: 7), 9)
        case .nextWeek: return at(next(weekday: 2), 8)
        }
    }

    var subtitle: String {
        let f = DateFormatter(); f.dateFormat = self == .laterToday || self == .thisEvening ? "h:mm a" : "EEE h:mm a"
        return f.string(from: date)
    }
}

struct SnoozeMenu: View {
    var onPick: (Date) -> Void
    @State private var custom = false
    var body: some View {
        ForEach(SnoozeChoice.allCases) { c in
            Button("\(c.label) — \(c.subtitle)") { onPick(c.date) }
        }
    }
}

struct DatePickerSheet: View {
    var title: String
    var action: String
    var onPick: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            DatePicker("", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical).labelsHidden()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action) { onPick(date); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

// MARK: Misc

extension Date {
    var listLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(self) { return "Yesterday" }
        if let d = cal.dateComponents([.day], from: self, to: Date()).day, d < 7 { return formatted(.dateTime.weekday(.abbreviated)) }
        if cal.isDate(self, equalTo: Date(), toGranularity: .year) { return formatted(.dateTime.month(.abbreviated).day()) }
        return formatted(date: .numeric, time: .omitted)
    }
}

struct Badge: View {
    var count: Int
    var body: some View {
        if count > 0 {
            Text("\(count)").font(.caption2.weight(.semibold)).monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

struct ToastView: View {
    var toast: Toast
    var onUndo: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            if toast.isError { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow) }
            Text(toast.message).font(.callout)
            if let u = toast.undoTitle {
                Button(u, action: onUndo).buttonStyle(.plain).font(.callout.weight(.semibold)).foregroundStyle(Color.accentColor)
                    .keyboardShortcut("z", modifiers: .command)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(.background, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator.opacity(0.5)))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }
}
