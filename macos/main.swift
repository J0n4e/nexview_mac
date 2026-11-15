// Nexview for macOS (Apple Silicon): a native window onto your own Nexview
// server (e.g. on Unraid). Each user signs in with their own account.
import Cocoa
import WebKit
import CryptoKit
import UserNotifications
import LocalAuthentication
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate,
                         WKScriptMessageHandler, UNUserNotificationCenterDelegate, NSWindowDelegate {
    var window: NSWindow!
    var webView: WKWebView!

    var store = ServerStore.load()
    var serverURL: URL? { store.current.flatMap { URL(string: $0.url) } }

    func applicationDidFinishLaunching(_ note: Notification) {
        // Menu bar icon first, before any window, as TokenEater does: menu bar managers
        // (Thaw, Ice, Bartender) pick items up as the app comes up.
        applyBackgroundMode()
        // One-time move of a server saved in plain text by an earlier build.
        if let old = UserDefaults.standard.string(forKey: "ServerURL") {
            if store.servers.isEmpty { store.add(Server(name: URL(string: old)?.host ?? "Server", url: old)) }
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
        Credentials.delete(server: cur.url)
        store.removeCurrent()
        if serverURL == nil { buildMenu(); askForServer(firstRun: true) } else { loadServer() }
    }

    /// Normalises "192.168.1.10:8000" or "nexview.example.com" to a full URL.
    func normalise(_ raw: String) -> URL? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if !t.contains("://") { t = "http://" + t }
        if !t.hasSuffix("/") { t += "/" }
        guard let u = URL(string: t), u.host != nil else { return nil }
        return u
    }

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
        // Check that a Nexview server answers before saving it.
        var req = URLRequest(url: u.appendingPathComponent("api/health")); req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                let ok = (resp as? HTTPURLResponse)?.statusCode == 200 &&
                    (data.flatMap { String(data: $0, encoding: .utf8) }?.contains("\"status\"") ?? false)
                let label = nf.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ? (u.host ?? "Server") : nf.stringValue
                if ok {
                    let srv = Server(name: label, url: u.absoluteString)
                    if editing { self.store.replaceCurrent(srv) } else { self.store.add(srv) }
                    self.loadServer()
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
        <div style="color:#999">\(serverURL?.absoluteString ?? "") — \(e.localizedDescription)</div>
        <div style="color:#777">Use View → Reload (⌘R) to retry, or check the address in Nexview → Settings…</div></body></html>
        """
        wv.loadHTMLString(html, baseURL: nil)
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
            if let user = m["user"] as? String { ensureAccessKey(for: user) }
        case "apikey":
            guard let srv = store.current, let key = m["key"] as? String, let user = m["user"] as? String else { break }
            var keys = store.apiKeys ?? [:]
            keys[srv.url] = AccessKey(key: key, id: m["id"] as? Int ?? 0, user: user)
            store.apiKeys = keys; store.save()
            keyRequested.remove(srv.url)
            pollAll()
        case "alive":
            flushReads()
        case "marked":
            guard let srv = store.current, let ids = m["ids"] as? [Int] else { break }
            var q = pendingReads; q[srv.url] = (q[srv.url] ?? []).filter { !ids.contains($0) }; pendingReads = q
            scheduleQuickPoll(srv)
        case "refresh":
            if let srv = store.current { scheduleQuickPoll(srv) }
        case "signedOut":
            // Signed out: this account should no longer notify this Mac.
            if let srv = store.current, store.apiKeys?[srv.url] != nil {
                store.apiKeys?[srv.url] = nil; store.save()
                counts[srv.url] = nil; updateBadge()
            }
        case "loginForm":
            offerTouchIDLogin()
        case "loggedIn":
            if let user = m["user"] as? String, let pass = m["pass"] as? String { offerToSave(user: user, pass: pass) }
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
            let unread = await get(srv, key, "api/notifications/unread/count")
            if unread.status == 401 {
                // Key revoked or expired: forget it; a new one is made the next time this account is open.
                store.apiKeys?[srv.url] = nil; store.save()
                counts[srv.url] = nil; updateBadge(); return
            }
            guard unread.status == 200 else { return }       // server unreachable: keep the last known count
            let pending = await get(srv, key, "api/admin/requests/pending/count")   // 403 for non-approvers
            let u = (unread.json as? [String: Any])?["unread"] as? Int ?? 0
            let p = pending.status == 200 ? ((pending.json as? [String: Any])?["pending"] as? Int ?? 0) : 0
            counts[srv.url] = u + p
            updateBadge()

            let list = await get(srv, key, "api/notifications?unread_only=true&limit=100")
            guard list.status == 200, let items = list.json as? [[String: Any]] else { return }
            let ids = items.compactMap { $0["id"] as? Int }
            removeDelivered(server: srv.url, keeping: Set(ids))
            let tag = Credentials.tag(srv.url, key.user)
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
            if !gone.isEmpty {
                DispatchQueue.main.async { self.shown.subtract(gone) }
                center.removeDeliveredNotifications(withIdentifiers: gone)
            }
        }
    }

    /// Notifications this app put into Notification Center and has not removed itself.
    var shown: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "ShownNotifications") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "ShownNotifications") }
    }
    var clearTimer: Timer?

    /// macOS does not reliably tell an app when its notifications are cleared from Notification Center,
    /// so look every few seconds: any of ours that vanished without us removing it was cleared by the user.
    func watchForClears() {
        clearTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
                let present = Set(delivered.map(\.request.identifier))
                DispatchQueue.main.async {
                    guard let self else { return }
                    let cleared = self.shown.subtracting(present)
                    guard !cleared.isEmpty else { return }
                    self.shown.subtract(cleared)
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

    func flushReads() {
        guard let srv = store.current, let ids = pendingReads[srv.url], !ids.isEmpty else { return }
        webView.evaluateJavaScript("window.__nexviewMacMarkRead && window.__nexviewMacMarkRead(\(ids))", completionHandler: nil)
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
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "nexview-\(server.url)-\(id)", content: c, trigger: nil))
        shown.insert("nexview-\(server.url)-\(id)")
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Nexview in front showing that same server: its bell already shows it.
        let srv = n.request.content.userInfo["server"] as? String
        done(NSApp.isActive && window.isKeyWindow && srv == store.current?.url ? [] : [.banner, .sound, .list])
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        let info = r.notification.request.content.userInfo
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

    // MARK: Touch ID sign-in
    var touchIDBusy = false

    func offerTouchIDLogin() {
        guard let srv = store.current, Credentials.exists(server: srv.url), !touchIDBusy else { return }
        touchIDBusy = true
        let ctx = LAContext()
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "sign in to \(srv.name)") { ok, _ in
            DispatchQueue.main.async {
                self.touchIDBusy = false
                guard ok, srv.url == self.store.current?.url, let cred = Credentials.load(server: srv.url) else { return }
                let js = "window.__nexviewMacFill && window.__nexviewMacFill(\(Self.jsString(cred.user)), \(Self.jsString(cred.pass)))"
                self.webView.evaluateJavaScript(js, completionHandler: nil)
            }
        }
    }

    static func jsString(_ s: String) -> String {
        let d = try! JSONSerialization.data(withJSONObject: [s]); let a = String(data: d, encoding: .utf8)!
        return String(a.dropFirst().dropLast())
    }

    func offerToSave(user: String, pass: String) {
        guard let srv = store.current else { return }
        if let have = Credentials.load(server: srv.url), have.user == user, have.pass == pass { return }
        if Credentials.declined(server: srv.url, user: user) { return }
        let a = NSAlert()
        a.messageText = "Sign in to “\(srv.name)” with Touch ID next time?"
        a.informativeText = "Your password for \(user) is encrypted by your Mac’s Secure Enclave and only filled in after Touch ID or your Mac password."
        a.addButton(withTitle: "Use Touch ID"); a.addButton(withTitle: "Not Now"); a.addButton(withTitle: "Never for This Account")
        switch a.runModal() {
        case .alertFirstButtonReturn: Credentials.save(server: srv.url, user: user, pass: pass)
        case .alertThirdButtonReturn: Credentials.decline(server: srv.url, user: user)
        default: break
        }
    }

    @objc func forgetSignIn() {
        guard let srv = store.current else { return }
        Credentials.delete(server: srv.url)
        let a = NSAlert(); a.messageText = "Saved sign-in for “\(srv.name)” removed."; a.runModal()
    }

    // MARK: navigation – external links go to the default browser
    func isLocal(_ url: URL) -> Bool {
        guard let s = serverURL else { return false }
        return url.host == s.host && url.port == s.port
    }

    func webView(_ wv: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.shouldPerformDownload { decisionHandler(.download); return }
        if let u = action.request.url, ["http", "https"].contains(u.scheme ?? ""), !isLocal(u) {
            NSWorkspace.shared.open(u); decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    func webView(_ wv: WKWebView, decidePolicyFor resp: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(resp.canShowMIMEType ? .allow : .download)
    }

    func webView(_ wv: WKWebView, createWebViewWith c: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = action.request.url {
            if isLocal(u) { wv.load(action.request) } else { NSWorkspace.shared.open(u) }
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
        add("Nexview", [mi("About Nexview", #selector(showAbout), ""), .separator(),
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
    @objc func openBrowser() { if let u = webView.url ?? serverURL { NSWorkspace.shared.open(u) } }
}

// MARK: server list, encrypted by the Secure Enclave (see SecureVault), never in plain-text prefs

struct Server: Codable { var name: String; var url: String }

struct ServerStore: Codable {
    var servers: [Server] = []
    var selected = 0
    var signins: [String: Credentials.Saved]? = [:]
    var apiKeys: [String: AccessKey]? = [:]
    var current: Server? { servers.indices.contains(selected) ? servers[selected] : nil }

    static func load() -> ServerStore {
        guard let d = SecureVault.read(), let s = try? JSONDecoder().decode(ServerStore.self, from: d) else { return ServerStore() }
        return s
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { SecureVault.write(d) }
    }

    mutating func add(_ s: Server) {
        if let i = servers.firstIndex(where: { $0.url == s.url }) { servers[i] = s; selected = i }
        else { servers.append(s); selected = servers.count - 1 }
        save()
    }
    mutating func replaceCurrent(_ s: Server) { if current != nil { servers[selected] = s; save() } else { add(s) } }
    mutating func update(_ i: Int, _ s: Server) { if servers.indices.contains(i) { servers[i] = s; save() } }
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

// MARK: saved sign-ins for Touch ID, kept in the Secure Enclave vault

enum Credentials {
    struct Saved: Codable { var user: String; var pass: String }
    // Sign-ins live in the same Secure Enclave–encrypted vault as the server list (see SecureVault).
    static var app: AppDelegate { NSApp.delegate as! AppDelegate }

    static func exists(server: String) -> Bool { load(server: server) != nil }
    static func load(server: String) -> Saved? { app.store.signins?[server] }
    static func save(server: String, user: String, pass: String) {
        var m = app.store.signins ?? [:]; m[server] = Saved(user: user, pass: pass)
        app.store.signins = m; app.store.save()
    }
    static func delete(server: String) {
        guard app.store.signins?[server] != nil else { return }
        app.store.signins?[server] = nil; app.store.save()
    }

    // "Never for this account" lives in prefs as a hash, so neither server nor username is readable there.
    static func tag(_ server: String, _ user: String) -> String {
        SHA256.hash(data: Data("\(user)@\(server)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func declined(server: String, user: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: "TouchIDDeclined") ?? []).contains(tag(server, user))
    }
    static func decline(server: String, user: String) {
        var l = UserDefaults.standard.stringArray(forKey: "TouchIDDeclined") ?? []
        l.append(tag(server, user)); UserDefaults.standard.set(l, forKey: "TouchIDDeclined")
    }
}

// MARK: Secure Enclave vault
//
// Servers and saved sign-ins are encrypted with a key that lives inside this Mac's
// Secure Enclave. The key never leaves the chip, so the file is useless on any other
// machine or if copied off this one, and it never asks for a password when the
// app is rebuilt or updated.

enum SecureVault {
    static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nexview for Mac", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return d
    }
    static var keyFile: URL { dir.appendingPathComponent("enclave.key") }
    static var vaultFile: URL { dir.appendingPathComponent("vault.bin") }
    static let info = Data("nexview-mac-vault-v1".utf8)

    struct Sealed: Codable { var ephemeral: Data; var box: Data }

    /// The Secure Enclave key (stored only as an opaque handle that just this Mac's chip can use).
    static func enclaveKey(create: Bool) -> SecureEnclave.P256.KeyAgreement.PrivateKey? {
        if let blob = try? Data(contentsOf: keyFile),
           let k = try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob) { return k }
        guard create, SecureEnclave.isAvailable, let k = try? SecureEnclave.P256.KeyAgreement.PrivateKey() else { return nil }
        try? k.dataRepresentation.write(to: keyFile, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
        return k
    }

    static func symmetric(_ secret: SharedSecret) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: info, outputByteCount: 32)
    }

    static func write(_ plain: Data) {
        guard let k = enclaveKey(create: true) else { return }
        let eph = P256.KeyAgreement.PrivateKey()
        guard let secret = try? eph.sharedSecretFromKeyAgreement(with: k.publicKey),
              let box = try? AES.GCM.seal(plain, using: symmetric(secret)).combined,
              let out = try? JSONEncoder().encode(Sealed(ephemeral: eph.publicKey.rawRepresentation, box: box)) else { return }
        try? out.write(to: vaultFile, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: vaultFile.path)
    }

    static func read() -> Data? {
        guard let raw = try? Data(contentsOf: vaultFile),
              let sealed = try? JSONDecoder().decode(Sealed.self, from: raw),
              let k = enclaveKey(create: false),
              let eph = try? P256.KeyAgreement.PublicKey(rawRepresentation: sealed.ephemeral),
              let secret = try? k.sharedSecretFromKeyAgreement(with: eph),
              let box = try? AES.GCM.SealedBox(combined: sealed.box) else { return nil }
        return try? AES.GCM.open(box, using: symmetric(secret))
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
