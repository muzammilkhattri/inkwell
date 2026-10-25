import SwiftUI
import WebKit

@MainActor
enum RemoteContentBlocker {
    static var list: WKContentRuleList?
    static func prepare() async {
        guard list == nil else { return }
        let rules = """
        [{"trigger":{"url-filter":"^https?://","resource-type":["document","image","style-sheet","font","media","raw","svg-document","script","fetch","websocket","other","ping"]},"action":{"type":"block"}}]
        """
        list = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "block-remote-v2", encodedContentRuleList: rules)
    }
}

/// Renders one email body. Remote content is blocked unless `allowRemote`; scripts in mail never run.
struct MessageWebView: NSViewRepresentable {
    var html: String
    var allowRemote: Bool
    var designed: Bool
    var inlineImages: [String: Data] = [:]
    /// Which message this is; part of the render key so two emails never share a view.
    var contentID: String = ""
    @Binding var height: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Shared by all message views; cookies are refused so trackers can't link one email's
    /// remote images to another's.
    static let dataStore: WKWebsiteDataStore = {
        let store = WKWebsiteDataStore.nonPersistent()
        store.httpCookieStore.setCookiePolicy(.disallow) {}
        return store
    }()
    /// Released web views, kept with their web process alive. Each new WKWebView otherwise
    /// starts its own WebContent process, which was most of the time to open an email.
    private static var pool: [NoScrollWebView] = []

    static func newWebView() -> NoScrollWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = dataStore
        config.userContentController.addUserScript(WKUserScript(source: """
            (function(){
              function post(){ window.webkit.messageHandlers.height.postMessage(Math.ceil(document.documentElement.scrollHeight)); }
              new ResizeObserver(post).observe(document.documentElement);
              window.addEventListener('load', post); setTimeout(post, 50); setTimeout(post, 500);
              document.addEventListener('click', function(e){
                var a = e.target.closest('a'); if(!a || !a.getAttribute('href')) return;
                e.preventDefault();
                window.webkit.messageHandlers.link.postMessage({href: a.href, text: (a.innerText||'').trim().slice(0,200)});
              }, true);
            })();
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let wv = NoScrollWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 10), configuration: config)
        wv.setValue(false, forKey: "drawsBackground")
        return wv
    }

    /// Starts web processes ahead of the first opened email (a thread shows a few at once).
    static func prewarm(_ count: Int = 2) {
        while pool.count < count {
            let wv = newWebView()
            wv.loadHTMLString("<html><body></body></html>", baseURL: nil)
            pool.append(wv)
        }
    }

    /// Emails rendered ahead of time (the next and previous in the list), keyed like `loadedKey`.
    private static var prerendered: [String: (view: NoScrollWebView, sink: HeightSink)] = [:]
    private static var prerenderOrder: [String] = []

    /// Everything that changes the rendered document: message, HTML, inline images, options.
    static func key(id: String, html: String, designed: Bool, inline: [String: Data], allowRemote: Bool, dark: Bool) -> String {
        var h = Hasher()
        // A message's content never changes, so with its id in the key, names and sizes suffice.
        for (cid, data) in inline.sorted(by: { $0.key < $1.key }) { h.combine(cid); h.combine(data.count) }
        return "\(id)|\(html.hashValue)|\(h.finalize())|\(designed)|\(allowRemote)|\(dark)"
    }
    var renderKey: String {
        MessageWebView.key(id: contentID, html: html, designed: designed, inline: inlineImages, allowRemote: allowRemote, dark: colorSchemeIsDark)
    }

    /// Lays out an email in a hidden web view so opening it only has to attach the view.
    /// Only with remote content blocked: nothing leaves the Mac for an email you haven't opened.
    static func prerender(id: String, html: String, designed: Bool, inline: [String: Data]) {
        guard let rules = RemoteContentBlocker.list else { return }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let k = key(id: id, html: html, designed: designed, inline: inline, allowRemote: false, dark: dark)
        guard prerendered[k] == nil else { return }
        let wv = pool.popLast() ?? newWebView()
        let sink = HeightSink()
        let uc = wv.configuration.userContentController
        uc.add(sink, name: "height")
        uc.removeAllContentRuleLists(); uc.add(rules)
        wv.loadHTMLString(document(html, designed: designed, dark: dark, inline: inline, allowRemote: false), baseURL: nil)
        prerendered[k] = (wv, sink)
        prerenderOrder.append(k)
        while prerenderOrder.count > 2 {
            let old = prerenderOrder.removeFirst()
            guard let e = prerendered.removeValue(forKey: old) else { continue }
            e.view.configuration.userContentController.removeScriptMessageHandler(forName: "height")
            recycle(e.view)
        }
    }

    final class HeightSink: NSObject, WKScriptMessageHandler {
        var height: CGFloat?
        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            if let h = message.body as? Double { height = CGFloat(h) }
        }
    }

    func makeNSView(context: Context) -> NoScrollWebView {
        let k = renderKey
        if let pre = MessageWebView.prerendered.removeValue(forKey: k) {
            MessageWebView.prerenderOrder.removeAll { $0 == k }
            let wv = pre.view
            let uc = wv.configuration.userContentController
            uc.removeScriptMessageHandler(forName: "height")
            uc.add(context.coordinator, name: "height")
            uc.add(context.coordinator, name: "link")
            wv.navigationDelegate = context.coordinator
            context.coordinator.loadedKey = k
            Perf.open("web view: pre-rendered")
            if let h = pre.sink.height { DispatchQueue.main.async { self.height = h } }
            // Its width changes once in the window; the page's ResizeObserver reports the new height.
            return wv
        }
        let wv = MessageWebView.pool.popLast() ?? MessageWebView.newWebView()
        let uc = wv.configuration.userContentController
        uc.add(context.coordinator, name: "height")
        uc.add(context.coordinator, name: "link")
        wv.navigationDelegate = context.coordinator
        context.coordinator.load(into: wv, parent: self)
        return wv
    }

    private static func recycle(_ wv: NoScrollWebView) {
        wv.stopLoading()
        guard pool.count < 4 else { return }
        wv.loadHTMLString("<html><body></body></html>", baseURL: nil)  // drop the old mail's DOM and images
        pool.append(wv)
    }

    static func dismantleNSView(_ wv: NoScrollWebView, coordinator: Coordinator) {
        let uc = wv.configuration.userContentController
        uc.removeScriptMessageHandler(forName: "height")
        uc.removeScriptMessageHandler(forName: "link")
        wv.navigationDelegate = nil
        recycle(wv)
    }

    func updateNSView(_ wv: NoScrollWebView, context: Context) {
        let key = renderKey
        if context.coordinator.loadedKey != key {
            context.coordinator.parent = self
            context.coordinator.load(into: wv, parent: self)
        }
    }

    /// Content Security Policy for the email. With remote content blocked it allows nothing off the
    /// Mac, even if the content-blocker list isn't compiled yet; either way frames, plugins,
    /// forms and scripts are off.
    static func csp(allowRemote: Bool) -> String {
        let common = "script-src 'none'; frame-src 'none'; child-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'"
        return allowRemote
            ? "default-src * data: blob: 'unsafe-inline'; \(common)"
            : "default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; media-src data:; \(common)"
    }

    static func document(_ html: String, designed: Bool, dark: Bool, inline: [String: Data], allowRemote: Bool) -> String {
        var body = html
        for (cid, data) in inline {
            body = body.replacingOccurrences(of: "cid:\(cid)", with: "data:image/*;base64,\(data.base64EncodedString())")
        }
        let card = designed && dark
        let text = dark && !designed ? "#E8E8EA" : "#1d1d1f"
        let link = dark && !designed ? "#7FA6FF" : "#0A62D0"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(csp(allowRemote: allowRemote))">
        <meta name="color-scheme" content="\(dark && !designed ? "dark" : "light")">
        <style>
        html,body{margin:0;padding:0;background:transparent;}
        body{font-family:-apple-system,system-ui,sans-serif;font-size:14px;line-height:1.57;color:\(text);word-wrap:break-word;overflow-wrap:anywhere;overflow:hidden;}
        \(card ? ".inkwell-card{background:#fff;color:#1d1d1f;border-radius:10px;padding:12px;}" : "")
        a{color:\(link);} img{max-width:100%;height:auto;} table{max-width:100% !important;}
        pre,code{white-space:pre-wrap;} blockquote{margin:0 0 0 .6em;padding-left:.8em;border-left:3px solid rgba(128,128,128,.4);color:inherit;opacity:.85;}
        </style></head><body><div class="inkwell-card">\(body)</div></body></html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: MessageWebView
        var loadedKey = ""
        init(_ p: MessageWebView) { parent = p }

        @MainActor func load(into wv: WKWebView, parent p: MessageWebView) {
            let dark = wv.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            loadedKey = p.renderKey
            let ucc = wv.configuration.userContentController
            ucc.removeAllContentRuleLists()
            if !p.allowRemote, let l = RemoteContentBlocker.list { ucc.add(l) }
            let doc = MessageWebView.document(p.html, designed: p.designed, dark: dark, inline: p.inlineImages, allowRemote: p.allowRemote)
            Perf.open("web view load: \(doc.utf8.count / 1024) KB html, \(p.inlineImages.count) inline images, remote \(p.allowRemote ? "on" : "off")")
            wv.loadHTMLString(doc, baseURL: nil)
        }

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "height", let h = message.body as? Double {
                let nh = CGFloat(h)
                DispatchQueue.main.async { if abs(self.parent.height - nh) > 1 { self.parent.height = nh } }
            } else if message.name == "link", let d = message.body as? [String: Any], let href = d["href"] as? String, let url = URL(string: href) {
                let text = d["text"] as? String ?? ""
                DispatchQueue.main.async { LinkOpener.open(url, displayedText: text) }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { Perf.open("web view rendered") }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { Perf.open("web view committed") }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            let scheme = action.request.url?.scheme?.lowercased() ?? ""
            // The email itself (loadHTMLString → about:blank) and inline data.
            if scheme == "about" || scheme == "data" { decisionHandler(.allow); return }
            // A click opens in the browser. Anything automatic — meta refresh, frames, form posts —
            // is refused, so an email can't load or swap in a remote page on its own.
            if action.navigationType == .linkActivated, let url = action.request.url { LinkOpener.open(url, displayedText: "") }
            decisionHandler(.cancel)
        }
    }
}

extension MessageWebView { var colorSchemeIsDark: Bool { colorScheme == .dark } }

final class NoScrollWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
}

@MainActor
enum LinkOpener {
    /// Opens links in the browser, warning if the visible text names a different site.
    static func open(_ url: URL, displayedText: String) {
        if url.scheme == "mailto" {
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            var d = OutgoingDraft()
            d.to = comps?.path ?? ""
            d.subject = comps?.queryItems?.first { $0.name.lowercased() == "subject" }?.value ?? ""
            let store = MailStore.shared
            d.accountId = store.accounts.first?.id; d.fromEmail = store.accounts.first?.email ?? ""
            store.compose(d)
            return
        }
        let clean = Privacy.stripParams(url: url)
        if let shownHost = hostIn(displayedText), let realHost = clean.host.map(normalizedHost),
           !sameSite(realHost, normalizedHost(shownHost)) {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "This link goes somewhere else"
            a.informativeText = "The text shows \(shownHost), but the link opens \(realHost). Phishing emails often do this."
            a.addButton(withTitle: "Don't Open")
            a.addButton(withTitle: "Open \(realHost)")
            if a.runModal() != .alertSecondButtonReturn { return }
        }
        NSWorkspace.shared.open(clean)
    }

    nonisolated static func normalizedHost(_ h: String) -> String {
        var s = h.lowercased()
        while s.hasSuffix(".") { s.removeLast() }
        return s.hasPrefix("www.") ? String(s.dropFirst(4)) : s
    }

    /// Same host, or one is a dot-delimited subdomain of the other (mail.paypal.com ~ paypal.com,
    /// but not attackerpaypal.com).
    nonisolated static func sameSite(_ a: String, _ b: String) -> Bool {
        a == b || a.hasSuffix("." + b) || b.hasSuffix("." + a)
    }

    private static func hostIn(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.contains(" "), t.contains(".") else { return nil }
        let withScheme = t.hasPrefix("http") ? t : "https://" + t
        guard let h = URL(string: withScheme)?.host, h.contains("."), h.split(separator: ".").last.map({ $0.count >= 2 }) == true else { return nil }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
}
