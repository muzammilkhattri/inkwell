import Foundation

/// Removes tracking pixels and tracking parameters before mail is shown.
enum Privacy {
    private static let trackingParams: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "utm_id", "gclid", "fbclid", "mc_cid", "mc_eid",
        "_hsenc", "_hsmi", "mkt_tok", "yclid", "dclid", "igshid", "oly_enc_id", "oly_anon_id", "vero_id", "trk", "trkCampaign",
        "s_cid", "ss_source", "ss_campaign_id", "__s", "rb_clickid", "wickedid", "ml_subscriber", "ml_subscriber_hash",
    ]
    private static let trackerHosts = [
        "mailtrack.io", "mixmax.com", "yesware.com", "bananatag.com", "streak.com", "superhuman.com", "list-manage.com/track",
        "sendgrid.net/wf/open", "mandrillapp.com/track", "open.convertkit", "pixel.", "/open.aspx", "/track/open", "/o.gif",
        "/trk?", "/open?", "/wf/open", "email.mg.", "/e/o/", "ct.sendgrid.net", "tracking", "beacon", "/1x1.", "spacer.gif",
    ]

    struct Result { var html: String; var trackersRemoved: Int; var hasRemoteImages: Bool }

    private static let imgTag = try! NSRegularExpression(pattern: "<img\\b[^>]*>", options: [.caseInsensitive])
    private static let href = try! NSRegularExpression(pattern: "href\\s*=\\s*\"([^\"]+)\"", options: [.caseInsensitive])
    private static let tinyW = try! NSRegularExpression(pattern: "width\\s*=\\s*[\"']?[01](px)?[\"'\\s>]")
    private static let tinyH = try! NSRegularExpression(pattern: "height\\s*=\\s*[\"']?[01](px)?[\"'\\s>]")
    private static let tinyStyle = try! NSRegularExpression(pattern: "(width|height)\\s*:\\s*[01]px")
    private static let remoteSrc = try! NSRegularExpression(pattern: "src\\s*=\\s*[\"']?https?://|url\\(\\s*['\"]?https?://", options: [.caseInsensitive])

    /// Cleaning is pure, and the same body is rendered many times; memoize recent results.
    private static let cache = NSCache<NSString, CleanBox>()
    private final class CleanBox { let r: Result; init(_ r: Result) { self.r = r } }

    static func clean(_ html: String) -> Result {
        let key = html as NSString
        if let hit = cache.object(forKey: key) { return hit.r }
        let r = cleanUncached(html)
        cache.setObject(CleanBox(r), forKey: key, cost: html.utf16.count)
        return r
    }

    static func cleanUncached(_ input: String) -> Result {
        var removed = 0
        // A real NSString (UTF-16 storage) makes NSRegularExpression far faster than a bridged Swift string.
        let ns = NSString(string: input)
        let html = ns as String
        let out = NSMutableString(capacity: ns.length)
        var last = 0
        // Single pass over <img> tags (drop pixels) and href="…" (strip tracking params).
        var edits: [(NSRange, String?)] = []
        for m in imgTag.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            if isTracker(ns.substring(with: m.range)) { removed += 1; edits.append((m.range, "")) }
        }
        for m in href.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let url = ns.substring(with: m.range(at: 1))
            guard url.has("?") else { continue }
            let stripped = stripParams(url)
            if stripped != url { edits.append((m.range, "href=\"\(stripped)\"")) }
        }
        edits.sort { $0.0.location < $1.0.location }
        for (range, replacement) in edits where range.location >= last {
            out.append(ns.substring(with: NSRange(location: last, length: range.location - last)))
            if let replacement { out.append(replacement) }
            last = range.location + range.length
        }
        out.append(ns.substring(from: last))
        let remote = remoteSrc.firstMatch(in: out as String, range: NSRange(location: 0, length: out.length)) != nil
        return Result(html: out as String, trackersRemoved: removed, hasRemoteImages: remote)
    }

    private static func isTracker(_ tag: String) -> Bool {
        let l = tag.lowercased()
        let r = NSRange(location: 0, length: (l as NSString).length)
        let tiny = tinyW.firstMatch(in: l, range: r) != nil && tinyH.firstMatch(in: l, range: r) != nil
        let styleTiny = tinyStyle.firstMatch(in: l, range: r) != nil
        let hidden = l.has("display:none") || l.has("display: none") || l.has("visibility:hidden")
        let known = trackerHosts.contains { l.has($0) }
        return tiny || styleTiny || hidden || (known && !l.has("logo"))
    }

    static func stripParams(_ raw: String) -> String {
        let decoded = raw.replacingOccurrences(of: "&amp;", with: "&")
        guard var comps = URLComponents(string: decoded), let items = comps.queryItems, !items.isEmpty else { return raw }
        let kept = items.filter { !trackingParams.contains($0.name.lowercased()) && !$0.name.lowercased().hasPrefix("utm_") }
        if kept.count == items.count { return raw }
        comps.queryItems = kept.isEmpty ? nil : kept
        return (comps.string ?? decoded).replacingOccurrences(of: "&", with: "&amp;")
    }

    static func stripParams(url: URL) -> URL {
        URL(string: stripParams(url.absoluteString).replacingOccurrences(of: "&amp;", with: "&")) ?? url
    }

    private static let designedCache = NSCache<NSString, NSNumber>()
    static func isDesignedCached(_ html: String) -> Bool {
        let k = html as NSString
        if let v = designedCache.object(forKey: k) { return v.boolValue }
        let v = isDesigned(html)
        designedCache.setObject(NSNumber(value: v), forKey: k)
        return v
    }

    /// Does this HTML look "designed" (newsletters, receipts) and should keep a light card in dark mode?
    static func isDesigned(_ html: String) -> Bool {
        let l = html.lowercased()
        return l.has("<table") || l.has("bgcolor") || l.has("background-color") || l.has("<img")
    }
}
