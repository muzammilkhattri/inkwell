import AppKit
import SwiftUI
import WebKit

/// `Inkwell --webtest <port>`: renders hostile emails through the real MessageWebView code path
/// and lets a local HTTP collector on <port> record any request they manage to make.
@MainActor
enum WebTest {
    static var keep: [Any] = []

    static func run() -> Never {
        let port = CommandLine.arguments.last ?? "8765"
        let base = "http://127.0.0.1:\(port)"
        let hostile = """
        <p>hi</p><img src="\(base)/img-PROBE">
        <iframe src="\(base)/iframe-PROBE"></iframe>
        <link rel="stylesheet" href="\(base)/css-PROBE">
        <div style="background:url(\(base)/bg-PROBE)">x</div>
        <object data="\(base)/object-PROBE"></object>
        <form action="\(base)/form-PROBE" method="post"><input name=a value=b></form>
        <meta http-equiv="refresh" content="0;url=\(base)/refresh-PROBE">
        """
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            await RemoteContentBlocker.prepare()
            for (label, allow, blockerReady) in [("blocked", false, true), ("blocked-no-blocker", false, false), ("allowed", true, true)] {
                let saved = RemoteContentBlocker.list
                if !blockerReady { RemoteContentBlocker.list = nil }
                let html = hostile.replacingOccurrences(of: "PROBE", with: label)
                let view = MessageWebView(html: html, allowRemote: allow, designed: false, contentID: label, height: .constant(0))
                let c = view.makeCoordinator()
                let wv = MessageWebView.newWebView()
                wv.navigationDelegate = c
                c.load(into: wv, parent: view)
                keep += [c, wv]
                RemoteContentBlocker.list = saved
                print("loaded \(label)"); fflush(stdout)
            }
            try? await Task.sleep(for: .seconds(4))
            print("done"); fflush(stdout)
            exit(0)
        }
        NSApplication.shared.run()
        exit(0)
    }
}
