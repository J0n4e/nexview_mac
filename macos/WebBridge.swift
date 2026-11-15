// The page side: messages from bridge.js, navigation and UI delegates, origin checks, the error page.
import Cocoa
import WebKit

extension AppDelegate {
    // MARK: messages from the page (bridge.js)
    func userContentController(_ c: WKUserContentController, didReceive msg: WKScriptMessage) {
        guard let m = msg.body as? [String: Any], let type = m["type"] as? String,
              let origin = msg.frameInfo.request.url, isLocal(origin) else { return }
        switch type {
        case "session":
            if let user = m["user"] as? String {
                if let srv = store.current, let k = store.apiKeys?[srv.url], k.user == user { tellPageKeyId(k.id) }
                flushKeyDeletions(for: user)
                ensureAccessKey(for: user)
            }
        case "apikey":
            guard let srv = store.current, let key = m["key"] as? String, let user = m["user"] as? String else { break }
            var keys = store.apiKeys ?? [:]
            // Account switch: the previous account's key can't be deleted from this session; remember it
            // and delete it the next time that account is signed in here.
            if let old = keys[srv.url], old.user != user { queueKeyDeletion(server: srv.url, old) }
            keys[srv.url] = AccessKey(key: key, id: m["id"] as? Int ?? 0, user: user)
            store.apiKeys = keys; store.save()
            keyRequested.remove(srv.url)
            resetBackoff(srv.url)
            pollAll()
        case "alive":
            if let srv = store.current, store.apiKeys?[srv.url] == nil, keyLost.remove(srv.url) != nil {
                // The key was dropped after a 401: ask the page to report its session again so a new one is made.
                webView.evaluateJavaScript("window.__nexviewMacResetSession && window.__nexviewMacResetSession()", completionHandler: nil)
            }
            flushReads()
        case "marked":
            guard let srv = store.current, let ids = m["ids"] as? [Int] else { break }
            var q = pendingReads; q[srv.url] = (q[srv.url] ?? []).filter { !ids.contains($0) }; pendingReads = q
            readsInFlight.remove(srv.url)
            scheduleQuickPoll(srv)
        case "refresh":
            if let srv = store.current { scheduleQuickPoll(srv) }
        case "signedOut":
            // Signed out: this account should no longer notify this Mac. bridge.js deletes the key on the
            // server just before the logout request; if that did not work, it is deleted later.
            if let srv = store.current, let k = store.apiKeys?[srv.url] {
                if (m["deletedId"] as? Int) != k.id { queueKeyDeletion(server: srv.url, k); deleteKeyDirect(server: srv.url, k) }
                store.apiKeys?[srv.url] = nil; store.save()
                counts[srv.url] = nil; updateBadge()
            }
        default: break
        }
    }

    func webView(_ wv: WKWebView, didFailProvisionalNavigation nav: WKNavigation!, withError error: Error) {
        let e = error as NSError
        if e.code == NSURLErrorCancelled { return }
        let html = """
        <html><body style="font:15px -apple-system;background:#141019;color:#ddd;display:flex;flex-direction:column;height:100vh;align-items:center;justify-content:center;gap:12px">
        <div style="font-size:20px;color:#ff3b4e">Can't reach your Nexview server</div>
        <div style="color:#999">\(Self.html(serverURL?.absoluteString ?? "")) — \(Self.html(e.localizedDescription))</div>
        <div style="color:#777">Use View → Reload (⌘R) to retry, or check the address in Nexview → Settings…</div></body></html>
        """
        wv.loadHTMLString(html, baseURL: nil)
    }

    static func html(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'", with: "&#39;")
    }

    static func jsString(_ s: String) -> String {
        let d = try! JSONSerialization.data(withJSONObject: [s]); let a = String(data: d, encoding: .utf8)!
        return String(a.dropFirst().dropLast())
    }

    // MARK: navigation – external links go to the default browser
    func isLocal(_ url: URL) -> Bool {
        guard let s = serverURL else { return false }
        return Self.sameOrigin(url, s)
    }

    static func sameOrigin(_ x: URL, _ y: URL) -> Bool {
        func origin(_ u: URL) -> (String, String, Int)? {
            guard let scheme = u.scheme?.lowercased(), let host = u.host?.lowercased() else { return nil }
            let port = u.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : -1)
            return (scheme, host, port)
        }
        guard let a = origin(x), let b = origin(y) else { return false }
        return a == b
    }

    /// Only these are ever handed to another app.
    static let externalSchemes: Set<String> = ["http", "https", "mailto"]

    func webView(_ wv: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.shouldPerformDownload { decisionHandler(.download); return }
        if let u = action.request.url, ["http", "https"].contains(u.scheme ?? ""), !isLocal(u) {
            if Self.externalSchemes.contains(u.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(u) }
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    func webView(_ wv: WKWebView, decidePolicyFor resp: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(resp.canShowMIMEType ? .allow : .download)
    }

    func webView(_ wv: WKWebView, createWebViewWith c: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = action.request.url {
            if isLocal(u) { wv.load(action.request) }
            else if Self.externalSchemes.contains(u.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(u) }
        }
        return nil
    }

    // MARK: JS dialogs, file pickers
    func webView(_ wv: WKWebView, runJavaScriptAlertPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert(); a.messageText = m; a.runModal(); completionHandler()
    }
    func webView(_ wv: WKWebView, runJavaScriptConfirmPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert(); a.messageText = m; a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }
    func webView(_ wv: WKWebView, runJavaScriptTextInputPanelWithPrompt p: String, defaultText: String?, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = NSAlert(); a.messageText = p
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); tf.stringValue = defaultText ?? ""
        a.accessoryView = tf; a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        completionHandler(a.runModal() == .alertFirstButtonReturn ? tf.stringValue : nil)
    }
    func webView(_ wv: WKWebView, runOpenPanelWith params: WKOpenPanelParameters, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let p = NSOpenPanel(); p.allowsMultipleSelection = params.allowsMultipleSelection
        p.canChooseDirectories = params.allowsDirectories
        completionHandler(p.runModal() == .OK ? p.urls : nil)
    }

    // MARK: downloads (backups, exports)
    func webView(_ wv: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ wv: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
    func download(_ d: WKDownload, decideDestinationUsing r: URLResponse, suggestedFilename name: String, completionHandler: @escaping (URL?) -> Void) {
        let p = NSSavePanel(); p.nameFieldStringValue = name
        p.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        completionHandler(p.runModal() == .OK ? p.url : nil)
    }
}
