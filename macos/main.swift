// Nexview for macOS (Apple Silicon): a native window onto your own Nexview
// server (e.g. on Unraid). Each user signs in with their own account.
import Cocoa
import WebKit
import CryptoKit
import UserNotifications
import Security
import os
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate,
                         WKScriptMessageHandler, UNUserNotificationCenterDelegate, NSWindowDelegate {
    var window: NSWindow!
    var webView: WKWebView!

    var store = ServerStore()
    var serverURL: URL? { store.current.flatMap { URL(string: $0.url) } }

    func applicationDidFinishLaunching(_ note: Notification) {
        // Menu bar icon first, before any window, as TokenEater does: menu bar managers
        // (Thaw, Ice, Bartender) pick items up as the app comes up.
        applyBackgroundMode()
        // Touch ID sign-in was removed: drop its leftover preference.
        UserDefaults.standard.removeObject(forKey: "TouchIDDeclined")
        let loaded = StoreLoader.load()
        store = loaded.store
        // Older builds could save the same server twice under spellings that differ only in case,
        // default port or trailing slash; keep the first, so every address (and SwiftUI row id) is unique.
        if store.removeDuplicates() { store.save() }
        // One-time move of a server saved in plain text by an earlier build.
        if let old = UserDefaults.standard.string(forKey: "ServerURL") {
            if store.servers.isEmpty { _ = store.add(Server(name: URL(string: old)?.host ?? "Server", url: old)) }
            UserDefaults.standard.removeObject(forKey: "ServerURL")
        }
        buildMenu()
        buildWindow()
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: "nexview", actions: [], intentIdentifiers: [], options: [.customDismissAction])
        ])
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        applyLoginItem()
        if serverURL == nil { askForServer(firstRun: true) } else { loadServer() }
        startPolling()
        watchForClears()
        Updater.shared.mainWindowVisible = { [weak self] in self?.window.isVisible == true }
        Updater.shared.start()
        if let msg = loaded.alert {
            DispatchQueue.main.async {
                let a = NSAlert(); a.alertStyle = .warning
                a.messageText = msg.title; a.informativeText = msg.text; a.runModal()
            }
        }
    }

    func buildWindow() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()   // keeps the login cookie between launches
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = true
        cfg.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15 NexviewMac"
        if let js = Bundle.main.url(forResource: "bridge", withExtension: "js").flatMap({ try? String(contentsOf: $0, encoding: .utf8) }) {
            cfg.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        cfg.userContentController.add(self, name: "nexview")
        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.setValue(false, forKey: "drawsBackground")

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Nexview"
        window.backgroundColor = NSColor(red: 0.08, green: 0.06, blue: 0.10, alpha: 1)
        window.contentView = webView
        let tb = NSToolbar(identifier: "main"); tb.displayMode = .iconOnly
        window.toolbar = tb; window.toolbarStyle = .unifiedCompact
        window.setContentSize(NSSize(width: 1400, height: 900))
        window.setFrameAutosaveName("NexviewMain")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func loadServer() {
        guard let u = serverURL else { return }
        window.title = store.current?.name ?? "Nexview"
        window.subtitle = u.host ?? ""
        setBadge(0)
        webView.load(URLRequest(url: u))
        buildMenu()
        SettingsModel.shared.refresh()
    }

    @objc func switchServer(_ sender: NSMenuItem) { selectServer(sender.tag) }

    func selectServer(_ i: Int) {
        store.select(i)
        webView.loadHTMLString("", baseURL: nil)
        loadServer()
    }

    @objc func removeServer() {
        guard let cur = store.current else { return }
        let a = NSAlert()
        a.messageText = "Remove “\(cur.name)”?"
        a.informativeText = "\(cur.url) will be removed from this Mac."
        a.addButton(withTitle: "Remove"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        removeServer(at: store.selected) { [weak self] in
            guard let self else { return }
            if self.serverURL == nil { self.buildMenu(); self.askForServer(firstRun: true) } else { self.loadServer() }
        }
    }

    /// Normalises "192.168.1.10:8000" or "nexview.example.com" to a full URL.
    /// Scheme and host are lowercased and a default port is dropped (see ServerURL).
    func normalise(_ raw: String) -> URL? { ServerURL.parse(raw) }

    /// "Already added as “Home”." when another saved server uses this address (`except`: the one being edited).
    func duplicateError(_ url: String, except: Int?) -> String? {
        guard let i = ServerURL.duplicate(of: url, in: store.servers.map(\.url), except: except) else { return nil }
        return "This address is already added as “\(store.servers[i].name)”."
    }

    /// Plain http:// to a host that is not on this Mac or the local network: passwords travel unencrypted.
    static func isInsecureRemote(_ u: URL) -> Bool {
        guard u.scheme?.lowercased() == "http", var h = u.host?.lowercased() else { return false }
        if h.hasPrefix("[") && h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        if h == "localhost" || h == "::1" || h.hasSuffix(".local") || h.hasPrefix("127.") || h.hasPrefix("10.") || h.hasPrefix("192.168.") { return false }
        let o = h.split(separator: ".")
        if o.count == 4, o[0] == "172", let b = Int(o[1]), (16...31).contains(b) { return false }
        return true
    }
    static let insecureWarning = "This address uses http:// over the internet: your password and session travel unencrypted. Use https:// if your server supports it."

    @objc func changeServer() { askForServer(firstRun: false) }
    @objc func addServer() { askForServer(firstRun: false, adding: true) }

    /// Adds a server, or edits the current one when `adding` is false and one exists.
    func askForServer(firstRun: Bool, adding: Bool = false, error: String? = nil, name: String? = nil, address: String? = nil) {
        let editing = !adding && store.current != nil
        let a = NSAlert()
        a.messageText = firstRun ? "Connect to your Nexview server" : (editing ? "Edit server" : "Add server")
        a.informativeText = (error.map { $0 + "\n\n" } ?? "") +
            "Enter the address of your Nexview server, e.g. http://192.168.1.10:8000 or https://nexview.example.com"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 56))
        let nf = NSTextField(frame: NSRect(x: 0, y: 32, width: 340, height: 24))
        nf.placeholderString = "Name (e.g. Home)"
        nf.stringValue = name ?? (editing ? store.current!.name : "")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        tf.placeholderString = "http://192.168.1.10:8000"
        tf.stringValue = address ?? (editing ? store.current!.url : "")
        box.addSubview(nf); box.addSubview(tf); nf.nextKeyView = tf
        a.accessoryView = box
        a.addButton(withTitle: "Connect")
        a.addButton(withTitle: firstRun ? "Quit" : "Cancel")
        a.window.initialFirstResponder = nf
        guard a.runModal() == .alertFirstButtonReturn else {
            if firstRun && serverURL == nil { NSApp.terminate(nil) }
            return
        }
        guard let u = normalise(tf.stringValue) else {
            askForServer(firstRun: firstRun, adding: adding, error: "That is not a valid address.", name: nf.stringValue, address: tf.stringValue); return
        }
        if let dup = duplicateError(u.absoluteString, except: editing ? store.selected : nil) {
            askForServer(firstRun: firstRun, adding: adding, error: dup, name: nf.stringValue, address: tf.stringValue); return
        }
        // Check that a Nexview server answers before saving it.
        var req = URLRequest(url: u.appendingPathComponent("api/v1/health")); req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                let ok = (resp as? HTTPURLResponse)?.statusCode == 200 &&
                    (data.flatMap { String(data: $0, encoding: .utf8) }?.contains("\"status\"") ?? false)
                let label = nf.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ? (u.host ?? "Server") : nf.stringValue
                if ok {
                    let srv = Server(name: label, url: u.absoluteString)
                    let err: String?
                    if editing { err = self.editServer(at: self.store.selected, srv, then: { self.loadServer() }) }
                    else { err = self.store.add(srv) ? nil : self.duplicateError(srv.url, except: nil) }
                    if let err {
                        self.askForServer(firstRun: firstRun, adding: adding, error: err, name: nf.stringValue, address: tf.stringValue); return
                    }
                    if !editing { self.loadServer() }
                    if Self.isInsecureRemote(u) {
                        let w = NSAlert(); w.alertStyle = .warning; w.messageText = "Unencrypted connection"
                        w.informativeText = Self.insecureWarning; w.runModal()
                    }
                }
                else { self.askForServer(firstRun: firstRun, adding: adding, error: "No Nexview server answered at \(u.absoluteString)" + (err.map { " (\($0.localizedDescription))" } ?? "") + ".", name: nf.stringValue, address: tf.stringValue) }
            }
        }.resume()
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

    // With "Run in background" on, closing the window keeps Nexview running so notifications still arrive.
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { !Prefs.keepRunning }

    /// Utilities such as Vorssaint quit an app as soon as its last window closes. With "Run in
    /// background" on, that is exactly when Nexview should stay, so a quit sent by another app right
    /// after the window closed is ignored. ⌘Q, the menu bar icon, the Dock and logout still quit.
    var windowClosedAt = Date.distantPast
    func applicationShouldTerminate(_ s: NSApplication) -> NSApplication.TerminateReply {
        guard Prefs.keepRunning, Date().timeIntervalSince(windowClosedAt) < 3,
              let ev = NSAppleEventManager.shared().currentAppleEvent,
              let pid = ev.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value,
              pid != ProcessInfo.processInfo.processIdentifier,
              let sender = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
              !["com.apple.loginwindow", "com.apple.dock"].contains(sender) else { return .terminateNow }
        return .terminateCancel
    }
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { window.makeKeyAndOrderFront(nil) }
        return true
    }

    // MARK: run in background (menu bar icon) and open at login (Login Items)

    var statusItem: NSStatusItem?

    /// "Open at login": adds or removes Nexview in System Settings → General → Login Items.
    func applyLoginItem() {
        let service = SMAppService.mainApp
        if Prefs.openAtLogin, service.status != .enabled { try? service.register() }
        if !Prefs.openAtLogin, service.status == .enabled || service.status == .requiresApproval { try? service.unregister() }
    }

    /// "Run in background" on: keep running after the window closes, with a menu bar icon. Off: no icon.
    func applyBackgroundMode() {
        let on = Prefs.keepRunning

        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            // Its own stable identity instead of the generic "Item-0", set right after creation,
            // exactly like TokenEater's StatusBarController. macOS 26 and menu bar managers track
            // items by this name; a stale "Item-0" state can keep an icon permanently hidden.
            item.autosaveName = "NexviewMenuBarIcon"
            item.button?.image = Self.menuBarIcon()
            item.button?.imagePosition = .imageLeading
            item.button?.toolTip = "Nexview"
            let m = NSMenu()
            m.addItem(withTitle: "Open Nexview", action: #selector(openFromMenuBar), keyEquivalent: "")
            m.addItem(.separator())
            m.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
            m.addItem(withTitle: "About Nexview", action: #selector(showAbout), keyEquivalent: "")
            m.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
            m.addItem(.separator())
            m.addItem(withTitle: "Quit Nexview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            m.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
            // Left click opens Nexview; right click shows this menu.
            statusMenu = m
            item.button?.target = self
            item.button?.action = #selector(statusItemClicked)
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            statusItem = item
        }
        // Show/hide rather than remove, so the item keeps its identity and position.
        statusItem?.isVisible = on
        // Without a menu bar icon there must be a Dock icon, or the app could not be reached.
        if !on, NSApp.activationPolicy() != .regular { openFromMenuBar() }
        setBadge(lastBadge)
    }

    var statusMenu: NSMenu?

    @objc func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp, let item = statusItem, let m = statusMenu {
            item.menu = m                       // attach just for this click, so a left click never opens it
            item.button?.performClick(nil)
            item.menu = nil
        } else {
            openFromMenuBar()
        }
    }

    /// Brings Nexview back: Dock icon, window, focus.
    @objc func openFromMenuBar() {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closing the main window with "Run in background" on leaves only the menu bar icon: no Dock icon.
    func windowWillClose(_ note: Notification) {
        guard (note.object as? NSWindow) === window, Prefs.keepRunning else { return }
        windowClosedAt = Date()
        DispatchQueue.main.async {
            // Settings or About still open count as using the app; they hide the Dock icon when they close.
            if !NSApp.windows.contains(where: { $0.isVisible && $0 !== self.window && $0.level == .normal && $0.styleMask.contains(.titled) }) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    /// The Nexview eye-and-play mark (from logo.svg) as a monochrome template, so macOS draws it white.
    static func menuBarIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 22, height: 16), flipped: true) { _ in
            let t = NSAffineTransform()
            t.scale(by: 22.0 / 44.0)            // logo spans x 10…54 (44 units) of its 64-unit viewBox
            t.translateX(by: -10, yBy: -16)
            let eye = NSBezierPath()
            eye.move(to: NSPoint(x: 12, y: 32))
            eye.curve(to: NSPoint(x: 32, y: 18.5), controlPoint1: NSPoint(x: 18.5, y: 23), controlPoint2: NSPoint(x: 25.5, y: 18.5))
            eye.curve(to: NSPoint(x: 52, y: 32), controlPoint1: NSPoint(x: 38.5, y: 18.5), controlPoint2: NSPoint(x: 45.5, y: 23))
            eye.curve(to: NSPoint(x: 32, y: 45.5), controlPoint1: NSPoint(x: 45.5, y: 41), controlPoint2: NSPoint(x: 38.5, y: 45.5))
            eye.curve(to: NSPoint(x: 12, y: 32), controlPoint1: NSPoint(x: 25.5, y: 45.5), controlPoint2: NSPoint(x: 18.5, y: 41))
            eye.close()
            eye.lineWidth = 4
            eye.lineJoinStyle = .round
            eye.transform(using: t as AffineTransform)
            let play = NSBezierPath()
            play.move(to: NSPoint(x: 28, y: 25.5)); play.line(to: NSPoint(x: 40, y: 32)); play.line(to: NSPoint(x: 28, y: 38.5)); play.close()
            play.transform(using: t as AffineTransform)
            NSColor.black.set()
            eye.stroke(); play.fill()
            return true
        }
        img.isTemplate = true
        return img
    }

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

    // MARK: notifications, checked by the app itself
    //
    // Every saved server with a read-only access key is asked directly once a minute, so
    // notifications arrive with the window closed and for every server, not just the one on screen.

    var pollTimer: Timer?
    var counts: [String: Int] = [:]          // server URL -> unread notifications + requests awaiting approval
    var keyRequested: Set<String> = []
    var keyLost: Set<String> = []           // servers whose key was dropped after a 401
    var quickPoll: DispatchWorkItem?

    func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.pollAll() }
        pollTimer?.tolerance = 10
        pollAll()
    }

    func pollAll() {
        for srv in store.servers {
            if let k = store.apiKeys?[srv.url] { poll(srv, k) } else { counts[srv.url] = nil }
        }
        updateBadge()
    }

    func scheduleQuickPoll(_ srv: Server) {
        quickPoll?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, let k = self.store.apiKeys?[srv.url] else { return }
            self.poll(srv, k)
        }
        quickPoll = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
    }

    /// The page reports who is signed in; make sure the app has its own key for that account.
    func ensureAccessKey(for user: String) {
        guard let srv = store.current, store.apiKeys?[srv.url]?.user != user, !keyRequested.contains(srv.url) else { return }
        keyRequested.insert(srv.url)
        let name = "Nexview for Mac – \(Host.current().localizedName ?? "Mac")"
        webView.evaluateJavaScript("window.__nexviewMacMakeKey && window.__nexviewMacMakeKey(\(Self.jsString(name)))", completionHandler: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.keyRequested.remove(srv.url) }
    }

    func get(_ srv: Server, _ key: AccessKey, _ path: String) async -> (status: Int, json: Any?) {
        guard let base = URL(string: srv.url), let u = URL(string: path, relativeTo: base) else { return (0, nil) }
        var req = URLRequest(url: u)
        req.setValue("Bearer \(key.key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return (0, nil) }
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, try? JSONSerialization.jsonObject(with: data))
    }

    func poll(_ srv: Server, _ key: AccessKey) {
        Task { @MainActor in
            let unread = await get(srv, key, "api/v1/notifications/unread/count")
            if unread.status == 401 {
                // Key revoked or expired: forget it; a new one is made the next time this account is open.
                store.apiKeys?[srv.url] = nil; store.save(); keyLost.insert(srv.url)
                counts[srv.url] = nil; updateBadge(); return
            }
            guard unread.status == 200 else { return }       // server unreachable: keep the last known count
            let pending = await get(srv, key, "api/v1/admin/requests/pending/count")   // 403 for non-approvers
            let u = (unread.json as? [String: Any])?["unread"] as? Int ?? 0
            let p = pending.status == 200 ? ((pending.json as? [String: Any])?["pending"] as? Int ?? 0) : 0
            counts[srv.url] = u + p
            updateBadge()

            let list = await get(srv, key, "api/notifications?unread_only=true&limit=100")
            guard list.status == 200, let items = list.json as? [[String: Any]] else { return }
            let ids = items.compactMap { $0["id"] as? Int }
            removeDelivered(server: srv.url, keeping: Set(ids))
            pruneShown(server: srv.url, unread: Set(ids))
            let tag = Self.notifyTag(srv.url, key.user)
            var seen = UserDefaults.standard.dictionary(forKey: "LastNotified") as? [String: Int] ?? [:]
            let maxID = ids.max() ?? 0
            guard let last = seen[tag] else {
                seen[tag] = maxID                              // first check: no flood of old notifications
                UserDefaults.standard.set(seen, forKey: "LastNotified"); return
            }
            let fresh = items.filter { ($0["id"] as? Int ?? 0) > last }
                             .sorted { ($0["id"] as? Int ?? 0) < ($1["id"] as? Int ?? 0) }
            if maxID > last { seen[tag] = maxID; UserDefaults.standard.set(seen, forKey: "LastNotified") }
            for n in fresh {
                notify(server: srv, kind: n["type"] as? String ?? "", title: n["message_title"] as? String ?? "",
                       season: n["season"] as? Int, ziel: n["ziel"] as? String, id: n["id"] as? Int ?? 0)
            }
        }
    }

    /// Read or deleted in Nexview: take it out of macOS Notification Center too.
    func removeDelivered(server: String, keeping unread: Set<Int>) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let gone = delivered.filter {
                let info = $0.request.content.userInfo
                guard info["server"] as? String == server, let id = info["id"] as? Int else { return false }
                return !unread.contains(id)
            }.map(\.request.identifier)
            guard !gone.isEmpty else { return }
            // Forget them first, so watchForClears never sees them vanish and takes it for a user clear.
            DispatchQueue.main.async {
                self.shown.subtract(gone)
                self.seenDelivered.subtract(gone)
                center.removeDeliveredNotifications(withIdentifiers: gone)
            }
        }
    }

    /// Notifications this app put into Notification Center and has not removed itself.
    /// Kept in insertion order and capped, so it cannot grow without bound.
    static let shownLimit = 500
    var shownList: [String] {
        get { UserDefaults.standard.stringArray(forKey: "ShownNotifications") ?? [] }
        set { UserDefaults.standard.set(Array(newValue.suffix(Self.shownLimit)), forKey: "ShownNotifications") }
    }
    var shown: Set<String> {
        get { Set(shownList) }
        set { shownList = shownList.filter { newValue.contains($0) } }
    }
    func addShown(_ ident: String) { var l = shownList.filter { $0 != ident }; l.append(ident); shownList = l }

    /// Drop entries for this server that are no longer unread there (read elsewhere or deleted).
    func pruneShown(server: String, unread: Set<Int>) {
        let prefix = "nexview-\(server)-"
        let keep = shownList.filter { ident in
            guard ident.hasPrefix(prefix), let id = Int(ident.dropFirst(prefix.count)) else { return true }
            return unread.contains(id)
        }
        if keep.count != shownList.count { shownList = keep; seenDelivered.formIntersection(Set(keep)) }
    }
    var clearTimer: Timer?
    /// Ours that Notification Center has actually listed. Only these can count as cleared: a fresh one
    /// may not be listed yet, and one held back while Nexview is in front is never listed at all.
    /// Starts empty: an entry joins only once Notification Center really lists it.
    var seenDelivered: Set<String> = []

    /// macOS does not reliably tell an app when its notifications are cleared from Notification Center,
    /// so look every few seconds: any of ours that vanished without us removing it was cleared by the user.
    func watchForClears() {
        clearTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
                let present = Set(delivered.map(\.request.identifier))
                DispatchQueue.main.async {
                    guard let self else { return }
                    let shown = self.shown
                    self.seenDelivered.formUnion(present.intersection(shown))
                    let cleared = shown.intersection(self.seenDelivered).subtracting(present)
                    guard !cleared.isEmpty else { return }
                    self.shown.subtract(cleared)
                    self.seenDelivered.subtract(cleared)
                    for ident in cleared {
                        // "nexview-<server URL>-<id>"
                        guard let dash = ident.lastIndex(of: "-"), let id = Int(ident[ident.index(after: dash)...]) else { continue }
                        let start = ident.index(ident.startIndex, offsetBy: "nexview-".count)
                        guard start < dash else { continue }
                        let server = String(ident[start..<dash])
                        self.markRead(server: server, id: id)
                    }
                }
            }
        }
        clearTimer?.tolerance = 1
    }

    /// Cleared in macOS: mark read in Nexview through the signed-in page (the app's own key may only read).
    /// Queued per server until that server's page is available.
    var pendingReads: [String: [Int]] {
        get { (UserDefaults.standard.dictionary(forKey: "PendingReads") as? [String: [Int]]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "PendingReads") }
    }

    func markRead(server: String, id: Int) {
        var q = pendingReads
        if !(q[server] ?? []).contains(id) { q[server, default: []].append(id) }
        pendingReads = q
        flushReads()
    }

    /// Servers with a mark-read send under way; cleared on "marked" or after 30 s.
    var readsInFlight: Set<String> = []

    func flushReads() {
        guard let srv = store.current, let ids = pendingReads[srv.url], !ids.isEmpty, !readsInFlight.contains(srv.url) else { return }
        readsInFlight.insert(srv.url)
        webView.evaluateJavaScript("window.__nexviewMacMarkRead && window.__nexviewMacMarkRead(\(ids))", completionHandler: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.readsInFlight.remove(srv.url) }
    }

    func updateBadge() { setBadge(store.servers.reduce(0) { $0 + (counts[$1.url] ?? 0) }) }

    // MARK: Dock badge + notifications
    var lastBadge = 0
    func setBadge(_ n: Int) {
        lastBadge = n
        NSApp.dockTile.badgeLabel = n > 0 && Prefs.badge ? String(n) : nil
        statusItem?.button?.title = (n > 0 && Prefs.badge ? " \(n)" : "")
    }

    static let notificationText: [String: String] = [
        "download_complete": "Ready to watch", "approved": "Request approved", "rejected": "Request declined",
        "cancelled": "Request cancelled", "request_pending": "New request waiting for approval",
        "feedback": "New quality feedback", "feedback_poor": "Quality problem reported",
        "feedback_reply": "Reply to your feedback", "ticket_new": "New ticket", "ticket_reply": "Reply to your ticket",
    ]

    func notify(server: Server, kind: String, title: String, season: Int?, ziel: String?, id: Int) {
        guard Prefs.notifications else { return }
        let c = UNMutableNotificationContent()
        c.title = Self.notificationText[kind] ?? "Nexview"
        c.body = title + (season.map { " — Season \($0)" } ?? "")
        c.subtitle = server.name
        c.sound = Prefs.sound ? .default : nil
        c.userInfo = ["server": server.url, "ziel": ziel ?? "", "id": id]
        c.categoryIdentifier = "nexview"           // with a dismiss action, so clearing it in macOS marks it read
        c.threadIdentifier = server.url
        // Recorded in `shown` only once willPresent lets it through (or it is delivered in the background).
        let ident = "nexview-\(server.url)-\(id)"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: ident, content: c, trigger: nil)) { err in
            guard err == nil else { return }
            DispatchQueue.main.async {
                // In the background willPresent is not called; the notification goes straight to Notification Center.
                if !(NSApp.isActive && self.window.isKeyWindow && server.url == self.store.current?.url) { self.addShown(ident) }
            }
        }
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Nexview in front showing that same server: its bell already shows it.
        let srv = n.request.content.userInfo["server"] as? String
        let suppress = NSApp.isActive && window.isKeyWindow && srv == store.current?.url
        // Only one that is really presented may later count as cleared by the user.
        if !suppress, srv != nil { DispatchQueue.main.async { self.addShown(n.request.identifier) } }
        done(suppress ? [] : [.banner, .sound, .list])
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        let info = r.notification.request.content.userInfo
        if info["update"] != nil {
            if r.actionIdentifier != UNNotificationDismissActionIdentifier { Updater.shared.showPending() }
            done(); return
        }
        if let srv = info["server"] as? String, let id = info["id"] as? Int { markRead(server: srv, id: id) }
        if r.actionIdentifier == UNNotificationDismissActionIdentifier { done(); return }   // cleared in macOS: just mark read
        if let srv = info["server"] as? String, let i = store.servers.firstIndex(where: { $0.url == srv }), i != store.selected { selectServer(i) }
        if let ziel = info["ziel"] as? String, !ziel.isEmpty, let base = serverURL,
           let u = URL(string: String(ziel.drop(while: { $0 == "/" })), relativeTo: base) {
            webView.load(URLRequest(url: u))
        }
        openFromMenuBar()
        done()
    }

    static func jsString(_ s: String) -> String {
        let d = try! JSONSerialization.data(withJSONObject: [s]); let a = String(data: d, encoding: .utf8)!
        return String(a.dropFirst().dropLast())
    }

    /// Key for per-account state in prefs (LastNotified), hashed so neither server nor username is readable there.
    static func notifyTag(_ server: String, _ user: String) -> String {
        SHA256.hash(data: Data("\(user)@\(server)".utf8)).map { String(format: "%02x", $0) }.joined()
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

    // MARK: menu
    func buildMenu() {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) {
            let it = NSMenuItem(); let m = NSMenu(title: title); items.forEach { m.addItem($0) }
            it.submenu = m; main.addItem(it)
        }
        func mi(_ t: String, _ s: Selector?, _ k: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: s, keyEquivalent: k); i.keyEquivalentModifierMask = mods; return i
        }
        add("Nexview", [mi("About Nexview", #selector(showAbout), ""), mi("Check for Updates…", #selector(checkForUpdates), ""), .separator(),
                        mi("Settings…", #selector(showSettings), ","), .separator(),
                        mi("Open in Browser", #selector(openBrowser), ""), .separator(),
                        mi("Hide Nexview", #selector(NSApplication.hide(_:)), "h"), .separator(),
                        mi("Quit Nexview", #selector(NSApplication.terminate(_:)), "q")])
        add("Edit", [mi("Undo", Selector(("undo:")), "z"), mi("Redo", Selector(("redo:")), "z", [.command, .shift]), .separator(),
                     mi("Cut", #selector(NSText.cut(_:)), "x"), mi("Copy", #selector(NSText.copy(_:)), "c"),
                     mi("Paste", #selector(NSText.paste(_:)), "v"), mi("Select All", #selector(NSText.selectAll(_:)), "a")])
        add("View", [mi("Reload", #selector(reload), "r"), mi("Back", #selector(goBack), "["), mi("Forward", #selector(goForward), "]"), .separator(),
                     mi("Zoom In", #selector(zoomIn), "+"), mi("Zoom Out", #selector(zoomOut), "-"), mi("Actual Size", #selector(zoomReset), "0"), .separator(),
                     mi("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])])
        add("Window", [mi("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"), mi("Close", #selector(NSWindow.performClose(_:)), "w")])
        NSApp.mainMenu = main
    }
    @objc func reload() { if webView.url == nil || webView.url?.scheme == "about" { loadServer() } else { webView.reload() } }
    @objc func goBack() { webView.goBack() }
    @objc func goForward() { webView.goForward() }
    @objc func zoomIn() { webView.pageZoom += 0.1 }
    @objc func zoomOut() { webView.pageZoom = max(0.3, webView.pageZoom - 0.1) }
    @objc func zoomReset() { webView.pageZoom = 1 }
    @objc func showSettings() { PanelWindows.showSettings() }
    @objc func showAbout() { PanelWindows.showAbout() }
    @objc func checkForUpdates() { Updater.shared.checkNow() }
    @objc func openBrowser() { if let u = webView.url ?? serverURL { NSWorkspace.shared.open(u) } }
}

// MARK: per-address state when a server is edited or removed, and deleting the app's keys on the server

extension AppDelegate {
    /// Keys still to be deleted on their server: server URL -> keys. Persisted, so a key whose delete
    /// failed (offline, or a different account is signed in) is deleted on a later session.
    static let keyDeletionsKey = "PendingKeyDeletions"
    var pendingKeyDeletions: [String: [[String: Any]]] {
        get { (UserDefaults.standard.dictionary(forKey: Self.keyDeletionsKey) as? [String: [[String: Any]]]) ?? [:] }
        set { UserDefaults.standard.set(newValue.filter { !$0.value.isEmpty }, forKey: Self.keyDeletionsKey) }
    }

    func queueKeyDeletion(server: String, _ k: AccessKey) {
        guard k.id > 0 else { return }
        var q = pendingKeyDeletions
        var l = (q[server] ?? []).filter { ($0["id"] as? Int) != k.id }
        l.append(["id": k.id, "user": k.user])
        q[server] = Array(l.suffix(20)); pendingKeyDeletions = q
    }

    func unqueueKeyDeletion(server: String, id: Int) {
        var q = pendingKeyDeletions
        q[server] = (q[server] ?? []).filter { ($0["id"] as? Int) != id }; pendingKeyDeletions = q
    }

    /// A session for `user` is open on the current page: delete that account's leftover keys through it.
    func flushKeyDeletions(for user: String) {
        guard let srv = store.current else { return }
        let current = store.apiKeys?[srv.url]?.id
        for e in pendingKeyDeletions[srv.url] ?? [] {
            guard e["user"] as? String == user, let id = e["id"] as? Int, id != current else { continue }
            deleteKeyViaPage(id) { [weak self] ok in if ok { self?.unqueueKeyDeletion(server: srv.url, id: id) } }
        }
    }

    func tellPageKeyId(_ id: Int) {
        guard id > 0 else { return }
        webView.evaluateJavaScript("window.__nexviewMacSetKeyId && window.__nexviewMacSetKeyId(\(id))", completionHandler: nil)
    }

    /// True when the page on screen is the given server (same scheme, host and port).
    func pageShows(_ server: String) -> Bool {
        guard let p = webView?.url, let s = URL(string: server) else { return false }
        return Self.sameOrigin(p, s)
    }

    /// Deletes a key with the signed-in page's session (DELETE /api/auth/me/schluessel/{id} in bridge.js).
    /// Calls back with true once the server confirmed (or the key was already gone); false otherwise, at most after 6 s.
    func deleteKeyViaPage(_ id: Int, done: @escaping (Bool) -> Void) {
        guard id > 0, let wv = webView else { done(false); return }
        var finished = false
        let finish: (Bool) -> Void = { ok in if !finished { finished = true; done(ok) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { finish(false) }
        wv.callAsyncJavaScript("return window.__nexviewMacDeleteKey ? await window.__nexviewMacDeleteKey(id) : false",
                               arguments: ["id": id], in: nil, in: .page) { r in
            DispatchQueue.main.async {
                if case .success(let v) = r { finish((v as? Bool) ?? ((v as? NSNumber)?.boolValue ?? false)) } else { finish(false) }
            }
        }
    }

    /// Best effort without the page: ask the server with the key itself. A read-only key may not be
    /// allowed to delete itself; then it simply stays queued.
    func deleteKeyDirect(server: String, _ k: AccessKey, done: ((Bool) -> Void)? = nil) {
        guard k.id > 0, let base = URL(string: server), let u = URL(string: "api/auth/me/schluessel/\(k.id)", relativeTo: base) else { done?(false); return }
        var req = URLRequest(url: u); req.httpMethod = "DELETE"; req.timeoutInterval = 10
        req.setValue("Bearer \(k.key)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            let st = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let ok = (200..<300).contains(st) || st == 404
            DispatchQueue.main.async {
                if ok { self.unqueueKeyDeletion(server: server, id: k.id) }
                done?(ok)
            }
        }.resume()
    }

    /// Deletes the key on its server: through the page if it shows that server, else directly; queued if neither worked.
    func deleteKeyOnServer(server: String, _ k: AccessKey, then: @escaping () -> Void) {
        queueKeyDeletion(server: server, k)
        let direct = { self.deleteKeyDirect(server: server, k) { _ in then() } }
        guard pageShows(server) else { direct(); return }
        deleteKeyViaPage(k.id) { ok in
            if ok { self.unqueueKeyDeletion(server: server, id: k.id); then() } else { direct() }
        }
    }

    /// Edits server `i`. Returns an error message (duplicate address) or nil; `then` runs once done
    /// (after the old key was deleted, if it had to be).
    ///
    /// Rule (ServerURL.sameInstance): same host and base path => same Nexview, so everything kept for the
    /// old address (key, queued mark-reads, notification state) moves to the new one; a scheme or port
    /// change keeps it. Otherwise it is another server: the old key belongs to the old server and is
    /// deleted there (best effort) and forgotten, and the old per-address state is dropped.
    @discardableResult
    func editServer(at i: Int, _ srv: Server, then: @escaping () -> Void = {}) -> String? {
        guard store.servers.indices.contains(i) else { return "This server no longer exists." }
        if let dup = duplicateError(srv.url, except: i) { return dup }
        let old = store.servers[i].url
        let key = store.apiKeys?[old]
        guard old != srv.url else { store.update(i, srv); then(); return nil }
        let same = ServerURL.sameInstance(old, srv.url)
        let wasShown = pageShows(old)
        if same { moveState(from: old, to: srv.url, user: key?.user) } else { dropState(old, user: key?.user) }
        guard store.update(i, srv) else { return duplicateError(srv.url, except: i) ?? "Could not save this server." }
        if !same, let key {
            // Delete through the old page while it is still loaded, then go on.
            unqueueKeyDeletionsMove(from: old, to: nil)
            if wasShown { deleteKeyViaPage(key.id) { ok in if !ok { self.deleteKeyDirect(server: old, key) }; then() } }
            else { deleteKeyDirect(server: old, key); then() }
        } else { then() }
        return nil
    }

    /// Removes server `i` from this Mac, deleting its key on the server first when possible (best effort);
    /// it is always forgotten locally.
    func removeServer(at i: Int, then: @escaping () -> Void) {
        guard store.servers.indices.contains(i) else { then(); return }
        let url = store.servers[i].url
        let key = store.apiKeys?[url]
        let finish = {
            self.dropState(url, user: key?.user)
            self.unqueueKeyDeletionsMove(from: url, to: nil)
            if let j = self.store.servers.firstIndex(where: { $0.url == url }) { self.store.remove(j) }
            then()
        }
        guard let key else { finish(); return }
        if pageShows(url) { deleteKeyViaPage(key.id) { ok in if !ok { self.deleteKeyDirect(server: url, key) }; finish() } }
        else { deleteKeyDirect(server: url, key); finish() }
    }

    /// Every piece of state kept per server URL, moved to a new address of the same server.
    func moveState(from old: String, to new: String, user: String?) {
        var q = pendingReads
        if let ids = q.removeValue(forKey: old) { q[new] = Array(Set((q[new] ?? []) + ids)).sorted() }
        pendingReads = q
        if let user {
            var seen = UserDefaults.standard.dictionary(forKey: "LastNotified") as? [String: Int] ?? [:]
            if let v = seen.removeValue(forKey: Self.notifyTag(old, user)) { seen[Self.notifyTag(new, user)] = v }
            UserDefaults.standard.set(seen, forKey: "LastNotified")
        }
        let oldPrefix = "nexview-\(old)-", newPrefix = "nexview-\(new)-"
        let moved: [String] = shownList.map { (s: String) -> String in s.hasPrefix(oldPrefix) ? newPrefix + String(s.dropFirst(oldPrefix.count)) : s }
        let renamed = Set(shownList.filter { $0.hasPrefix(oldPrefix) })
        shownList = moved
        seenDelivered.subtract(renamed)
        removeDeliveredFor(prefix: oldPrefix)
        unqueueKeyDeletionsMove(from: old, to: new)
        if readsInFlight.remove(old) != nil { readsInFlight.insert(new) }
        if keyLost.remove(old) != nil { keyLost.insert(new) }
        if keyRequested.remove(old) != nil { keyRequested.insert(new) }
        if let c = counts.removeValue(forKey: old) { counts[new] = c }
        SettingsModel.shared.health[old] = nil
        updateBadge()
    }

    /// Forgets everything kept for a server URL (not its queued key deletions, see unqueueKeyDeletionsMove).
    func dropState(_ url: String, user: String?) {
        var q = pendingReads; q[url] = nil; pendingReads = q
        if let user {
            var seen = UserDefaults.standard.dictionary(forKey: "LastNotified") as? [String: Int] ?? [:]
            seen[Self.notifyTag(url, user)] = nil
            UserDefaults.standard.set(seen, forKey: "LastNotified")
        }
        let prefix = "nexview-\(url)-"
        let gone = Set(shownList.filter { $0.hasPrefix(prefix) })
        shownList = shownList.filter { !gone.contains($0) }
        seenDelivered.subtract(gone)
        removeDeliveredFor(prefix: prefix)
        readsInFlight.remove(url); keyLost.remove(url); keyRequested.remove(url)
        counts[url] = nil
        SettingsModel.shared.health[url] = nil
        updateBadge()
    }

    /// Takes this app's notifications for an old address out of Notification Center (they would point at it).
    func removeDeliveredFor(prefix: String) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let ids = delivered.map(\.request.identifier).filter { $0.hasPrefix(prefix) }
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    /// Moves (or with `to == nil` drops) the queue of keys still to delete for an address.
    func unqueueKeyDeletionsMove(from old: String, to new: String?) {
        var q = pendingKeyDeletions
        guard let l = q.removeValue(forKey: old) else { return }
        if let new { q[new] = (q[new] ?? []) + l }
        pendingKeyDeletions = q
    }

    /// "Sign out everywhere": delete the current page's key through it, queue the rest, forget all.
    func forgetAllKeys(then: @escaping () -> Void) {
        let keys = store.apiKeys ?? [:]
        for (url, k) in keys { queueKeyDeletion(server: url, k); deleteKeyDirect(server: url, k) }
        let finish = { self.store.apiKeys = [:]; self.store.save(); self.counts = [:]; self.updateBadge(); then() }
        if let cur = store.current, let k = keys[cur.url], pageShows(cur.url) {
            deleteKeyViaPage(k.id) { ok in if ok { self.unqueueKeyDeletion(server: cur.url, id: k.id) }; finish() }
        } else { finish() }
    }
}

// MARK: server list and read-only keys, kept in the macOS Keychain (never in plain-text prefs)

let storeLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "io.github.derkezorm.nexview.macos", category: "store")

struct Server: Codable { var name: String; var url: String }

struct ServerStore: Codable {
    var servers: [Server] = []
    var selected = 0
    var apiKeys: [String: AccessKey]? = [:]
    var current: Server? { servers.indices.contains(selected) ? servers[selected] : nil }

    func save() {
        let d: Data
        do { d = try JSONEncoder().encode(self) } catch {
            storeLog.error("Encoding the store failed: \(error.localizedDescription, privacy: .public)"); return
        }
        guard !KeychainStore.writesBlocked else {
            storeLog.error("Not saving: the Keychain item could not be read at launch and is left untouched"); return
        }
        let st = KeychainStore.write(d)
        if st != errSecSuccess { storeLog.error("Saving the store to the Keychain failed: \(KeychainStore.describe(st), privacy: .public)") }
    }

    /// Adds and selects a server. Refuses (returns false) an address another saved server already uses
    /// (compared normalised: see ServerURL.key), so every entry and SwiftUI row id stays unique.
    @discardableResult
    mutating func add(_ s: Server) -> Bool {
        guard ServerURL.duplicate(of: s.url, in: servers.map(\.url)) == nil else { return false }
        servers.append(s); selected = servers.count - 1
        save(); return true
    }
    /// Store-only edits; per-address state is moved by AppDelegate.editServer, which should be used instead.
    @discardableResult
    mutating func replaceCurrent(_ s: Server) -> Bool { current != nil ? update(selected, s) : add(s) }
    @discardableResult
    mutating func update(_ i: Int, _ s: Server) -> Bool {
        guard servers.indices.contains(i), ServerURL.duplicate(of: s.url, in: servers.map(\.url), except: i) == nil else { return false }
        if servers[i].url != s.url, let k = apiKeys?[servers[i].url] {
            apiKeys?[servers[i].url] = nil
            if ServerURL.sameInstance(servers[i].url, s.url) { apiKeys?[s.url] = k }   // see ServerURL.sameInstance
        }
        servers[i] = s; save(); return true
    }
    /// Drops later entries whose address duplicates an earlier one. True if anything changed.
    mutating func removeDuplicates() -> Bool {
        let cur = current.map { ServerURL.key($0.url) }
        var seen = Set<String>(), out: [Server] = []
        for s in servers where seen.insert(ServerURL.key(s.url)).inserted { out.append(s) }
        guard out.count != servers.count else { return false }
        let kept = Set(out.map(\.url))
        apiKeys = apiKeys?.filter { kept.contains($0.key) }
        servers = out
        selected = servers.firstIndex { ServerURL.key($0.url) == cur } ?? 0
        return true
    }
    mutating func remove(_ i: Int) {
        guard servers.indices.contains(i) else { return }
        apiKeys?[servers[i].url] = nil
        servers.remove(at: i)
        if selected == i { selected = 0 } else if selected > i { selected -= 1 }
        save()
    }
    mutating func move(from: IndexSet, to: Int) {
        let cur = current?.url
        servers.move(fromOffsets: from, toOffset: to)
        selected = servers.firstIndex { $0.url == cur } ?? 0
        save()
    }
    mutating func removeCurrent() { if let c = current { apiKeys?[c.url] = nil; servers.remove(at: selected); selected = 0; save() } }
    mutating func select(_ i: Int) { if servers.indices.contains(i) { selected = i; save() } }
}

/// A read-only Nexview access key the app made for itself, so it can check notifications on its own.
struct AccessKey: Codable { var key: String; var id: Int; var user: String }

// MARK: Keychain item

/// One generic-password item (service = bundle id, account "store") holding the JSON-encoded store.
/// No biometry or user presence is required to read it. Uses the login keychain: the data-protection
/// keychain needs a signed application identifier, which ad-hoc builds don't have.
enum KeychainStore {
    static var service: String { Bundle.main.bundleIdentifier ?? "io.github.derkezorm.nexview.macos" }
    static let account = "store"
    /// Set when the item exists but could not be read, so a save can't overwrite data we never saw.
    static var writesBlocked = false

    enum ReadResult { case missing, data(Data), failure(OSStatus) }

    static func describe(_ st: OSStatus) -> String {
        "\(st) (\((SecCopyErrorMessageString(st, nil) as String?) ?? "unknown error"))"
    }

    static func query(_ account: String) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        return q
    }

    static func read(account: String = account) -> ReadResult {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        switch st {
        case errSecSuccess:
            guard let d = out as? Data else { return .failure(errSecDecode) }
            return .data(d)
        case errSecItemNotFound: return .missing
        default: return .failure(st)
        }
    }

    /// Updates the item, or adds it when it doesn't exist yet.
    @discardableResult
    static func write(_ d: Data, account: String = account) -> OSStatus {
        let st = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: d] as CFDictionary)
        guard st == errSecItemNotFound else { return st }
        var add = query(account)
        add[kSecValueData as String] = d
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "Nexview for Mac"
        return SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: loading at launch, including the one-time move out of the old Secure Enclave vault

enum StoreLoader {
    struct Message { var title: String; var text: String }

    static func load() -> (store: ServerStore, alert: Message?) {
        switch KeychainStore.read() {
        case .data(let d):
            do { return (try JSONDecoder().decode(ServerStore.self, from: d), nil) } catch {
                storeLog.error("Keychain store is undecodable: \(error.localizedDescription, privacy: .public)")
                return resetCorrupt(d)
            }
        case .failure(let st):
            storeLog.error("Reading the Keychain store failed: \(KeychainStore.describe(st), privacy: .public)")
            KeychainStore.writesBlocked = true
            return (ServerStore(), Message(title: "Nexview couldn’t read its saved servers",
                text: "The macOS Keychain refused access (\(KeychainStore.describe(st))). Nothing was changed; quit and reopen Nexview to try again. Changes made in this session won’t be saved."))
        case .missing:
            return migrateLegacyVault()
        }
    }

    /// Keeps a copy of unreadable data as its own item before starting over, so nothing is lost silently.
    static func resetCorrupt(_ d: Data) -> (store: ServerStore, alert: Message?) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let copy = "store.corrupt.\(stamp)"
        let st = KeychainStore.write(d, account: copy)
        guard st == errSecSuccess else {
            storeLog.error("Could not back up the undecodable store: \(KeychainStore.describe(st), privacy: .public); leaving it untouched")
            KeychainStore.writesBlocked = true
            return (ServerStore(), Message(title: "Nexview couldn’t read its saved servers",
                text: "The saved data in the Keychain is damaged and could not be backed up, so it was left untouched. Changes made in this session won’t be saved."))
        }
        storeLog.notice("Undecodable store backed up to Keychain account \(copy, privacy: .public)")
        ServerStore().save()
        return (ServerStore(), Message(title: "Your saved servers couldn’t be read",
            text: "Nexview’s saved data in the Keychain was damaged. A copy was kept in the Keychain as “\(copy)”. Please add your servers again in Settings."))
    }

    static func migrateLegacyVault() -> (store: ServerStore, alert: Message?) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: LegacyVault.vaultFile.path) else { return (ServerStore(), nil) }   // fresh install
        guard let plain = LegacyVault.read() else {
            storeLog.error("Old vault could not be decrypted; keeping it as .bak")
            LegacyVault.setAside()
            return (ServerStore(), Message(title: "Please add your servers again",
                text: "Nexview now keeps your servers in the macOS Keychain, but the old saved data on this Mac could not be read. It was kept as a backup (vault.bin.bak). Add your servers again in Settings; you sign in through the page as before."))
        }
        let store: ServerStore
        do { store = try JSONDecoder().decode(ServerStore.self, from: plain) } catch {
            storeLog.error("Old vault decrypted but is undecodable: \(error.localizedDescription, privacy: .public); keeping it as .bak")
            LegacyVault.setAside()
            return (ServerStore(), Message(title: "Please add your servers again",
                text: "Nexview now keeps your servers in the macOS Keychain, but the old saved data on this Mac could not be read. It was kept as a backup (vault.bin.bak). Add your servers again in Settings."))
        }
        // Re-encoding drops the saved sign-ins (passwords): ServerStore has no field for them.
        guard let d = try? JSONEncoder().encode(store) else { return (store, nil) }
        let st = KeychainStore.write(d)
        guard st == errSecSuccess else {
            storeLog.error("Migration: writing to the Keychain failed: \(KeychainStore.describe(st), privacy: .public); old vault kept")
            return (store, nil)
        }
        guard case .data(let back) = KeychainStore.read(), back == d,
              (try? JSONDecoder().decode(ServerStore.self, from: back)) != nil else {
            storeLog.error("Migration: Keychain read-back did not match; old vault kept")
            return (store, nil)
        }
        LegacyVault.deleteFiles()
        storeLog.notice("Migrated \(store.servers.count) server(s) from the old vault to the Keychain; saved passwords deleted")
        return (store, nil)
    }
}

// MARK: legacy Secure Enclave vault (read-only, for the one-time migration)
//
// Up to 0.1.3 the store, including saved passwords, was encrypted with a Secure Enclave key whose
// opaque handle lived in enclave.key next to vault.bin. Only reading it is kept here.

enum LegacyVault {
    static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nexview for Mac", isDirectory: true)
    }
    static var keyFile: URL { dir.appendingPathComponent("enclave.key") }
    static var vaultFile: URL { dir.appendingPathComponent("vault.bin") }
    static let info = Data("nexview-mac-vault-v1".utf8)

    struct Sealed: Codable { var ephemeral: Data; var box: Data }

    static func read() -> Data? {
        guard let raw = try? Data(contentsOf: vaultFile),
              let sealed = try? JSONDecoder().decode(Sealed.self, from: raw),
              let blob = try? Data(contentsOf: keyFile),
              let k = try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob),
              let eph = try? P256.KeyAgreement.PublicKey(rawRepresentation: sealed.ephemeral),
              let secret = try? k.sharedSecretFromKeyAgreement(with: eph),
              let box = try? AES.GCM.SealedBox(combined: sealed.box) else { return nil }
        let key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: info, outputByteCount: 32)
        return try? AES.GCM.open(box, using: key)
    }

    /// The Secure Enclave key exists only as this opaque file (no Keychain reference), so deleting it destroys the key.
    static func deleteFiles() {
        for f in [vaultFile, keyFile] where FileManager.default.fileExists(atPath: f.path) {
            do { try FileManager.default.removeItem(at: f) } catch {
                storeLog.error("Could not delete \(f.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Unreadable: keep both files as .bak (never delete them) and start empty.
    static func setAside() {
        let fm = FileManager.default
        for f in [vaultFile, keyFile] where fm.fileExists(atPath: f.path) {
            var dest = f.appendingPathExtension("bak")
            if fm.fileExists(atPath: dest.path) { dest = f.appendingPathExtension("\(Int(Date().timeIntervalSince1970)).bak") }
            do { try fm.moveItem(at: f, to: dest) } catch {
                storeLog.error("Could not rename \(f.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
