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

    // Stored state lives here (extensions can't hold stored properties); the code using it is in
    // NotificationPoller.swift, WebBridge.swift and ServerState.swift.
    var windowClosedAt = Date.distantPast   // see applicationShouldTerminate
    var statusItem: NSStatusItem?
    var statusMenu: NSMenu?
    var pollTimer: Timer?
    var counts: [String: Int] = [:]          // server URL -> unread notifications + requests awaiting approval
    var keyRequested: Set<String> = []
    var keyLost: Set<String> = []           // servers whose key was dropped after a 401
    var quickPoll: DispatchWorkItem?
    var clearTimer: Timer?                  // runs only while there are delivered notifications to watch
    /// Ours that Notification Center has actually listed. Only these can count as cleared: a fresh one
    /// may not be listed yet, and one held back while Nexview is in front is never listed at all.
    /// Starts empty: an entry joins only once Notification Center really lists it.
    var seenDelivered: Set<String> = []
    /// Servers with a mark-read send under way; cleared on "marked" or after 30 s.
    var readsInFlight: Set<String> = []
    var lastBadge = 0
    /// Polling back-off per server URL (see Backoff.swift): consecutive failures and the earliest next check.
    var pollFailures: [String: Int] = [:]
    var nextPollAt: [String: Date] = [:]

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
        if let cur = store.current { resetBackoff(cur.url) }   // opened or reloaded: check it at the normal rate again
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

    // With "Run in background" on, closing the window keeps Nexview running so notifications still arrive.
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { !Prefs.keepRunning }

    /// Utilities such as Vorssaint quit an app as soon as its last window closes. With "Run in
    /// background" on, that is exactly when Nexview should stay, so a quit sent by another app right
    /// after the window closed is ignored. ⌘Q, the menu bar icon, the Dock and logout still quit.
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
    @objc func reload() {
        if let cur = store.current { resetBackoff(cur.url) }
        if webView.url == nil || webView.url?.scheme == "about" { loadServer() } else { webView.reload() }
    }
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

// App entry. The only top-level code in the app; every other file holds declarations only.
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.regular)
NSApplication.shared.run()
