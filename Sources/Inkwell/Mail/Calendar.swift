import Foundation

struct CalendarInvite: Hashable {
    var uid: String
    var summary: String
    var start: Date?
    var end: Date?
    var allDay: Bool
    var location: String
    var organizer: EmailAddress?
    var attendees: [EmailAddress]
    var method: String
    var sequence: String
    var raw: String

    static func parse(_ ics: String) -> CalendarInvite? {
        // Unfold lines
        let unfolded = ics.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n ", with: "").replacingOccurrences(of: "\n\t", with: "")
        var inEvent = false
        var inv = CalendarInvite(uid: "", summary: "", start: nil, end: nil, allDay: false, location: "", organizer: nil, attendees: [], method: "REQUEST", sequence: "0", raw: ics)
        for line in unfolded.split(separator: "\n") {
            let l = String(line)
            if l.hasPrefix("METHOD:") { inv.method = String(l.dropFirst(7)) }
            if l == "BEGIN:VEVENT" { inEvent = true; continue }
            if l == "END:VEVENT" { break }
            guard inEvent, let colon = l.firstIndex(of: ":") else { continue }
            let keyPart = String(l[..<colon])
            let value = String(l[l.index(after: colon)...])
            let key = keyPart.split(separator: ";").first.map(String.init)?.uppercased() ?? ""
            let params = keyPart.split(separator: ";").dropFirst().reduce(into: [String: String]()) { d, p in
                let kv = p.split(separator: "=", maxSplits: 1); if kv.count == 2 { d[String(kv[0]).uppercased()] = String(kv[1]).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            }
            switch key {
            case "UID": inv.uid = value
            case "SUMMARY": inv.summary = unescape(value)
            case "LOCATION": inv.location = unescape(value)
            case "SEQUENCE": inv.sequence = value
            case "DTSTART": (inv.start, inv.allDay) = parseDate(value, tz: params["TZID"])
            case "DTEND": inv.end = parseDate(value, tz: params["TZID"]).0
            case "ORGANIZER": inv.organizer = EmailAddress(name: params["CN"] ?? "", email: value.replacingOccurrences(of: "mailto:", with: "", options: .caseInsensitive))
            case "ATTENDEE": inv.attendees.append(EmailAddress(name: params["CN"] ?? "", email: value.replacingOccurrences(of: "mailto:", with: "", options: .caseInsensitive)))
            default: break
            }
        }
        return inv.uid.isEmpty && inv.summary.isEmpty ? nil : inv
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\,", with: ",").replacingOccurrences(of: "\\;", with: ";").replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func parseDate(_ v: String, tz: String?) -> (Date?, Bool) {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        if v.count == 8 { f.dateFormat = "yyyyMMdd"; f.timeZone = .current; return (f.date(from: v), true) }
        if v.hasSuffix("Z") { f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"; f.timeZone = TimeZone(identifier: "UTC"); return (f.date(from: v), false) }
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        f.timeZone = tz.flatMap { TimeZone(identifier: $0) } ?? .current
        return (f.date(from: v), false)
    }

    enum Response: String { case accepted = "ACCEPTED", tentative = "TENTATIVE", declined = "DECLINED"
        var verb: String { self == .accepted ? "Accepted" : self == .tentative ? "Tentative" : "Declined" } }

    func replyICS(attendee: EmailAddress, response: Response) -> String {
        let stamp: String = {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            return f.string(from: Date())
        }()
        // Reuse original DTSTART/DTEND lines so time zones round-trip.
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n ", with: "").split(separator: "\n").map(String.init)
        let dtLines = lines.filter { $0.hasPrefix("DTSTART") || $0.hasPrefix("DTEND") }
        var out = ["BEGIN:VCALENDAR", "PRODID:-//Inkwell//EN", "VERSION:2.0", "METHOD:REPLY", "BEGIN:VEVENT",
                   "UID:\(uid)", "SEQUENCE:\(sequence)", "DTSTAMP:\(stamp)"] + dtLines
        if let o = organizer { out.append("ORGANIZER:mailto:\(o.email)") }
        out.append("ATTENDEE;PARTSTAT=\(response.rawValue);CN=\(attendee.name.isEmpty ? attendee.email : attendee.name):mailto:\(attendee.email)")
        out.append("SUMMARY:\(summary)")
        out += ["END:VEVENT", "END:VCALENDAR"]
        return out.joined(separator: "\r\n")
    }
}
