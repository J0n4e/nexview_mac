import AppKit
import UserNotifications

/// Looks for new releases of Nexview for Mac on GitHub and, when asked, installs one and restarts.
/// The app is signed ad hoc and built without Xcode, so this is a small updater of its own, not Sparkle.
final class Updater: NSObject {
    static let shared = Updater()
    static let latestURL = URL(string: "https://api.github.com/repos/J0n4e/nexview_mac/releases/latest")!
    static let bundleID = "io.github.derkezorm.nexview.macos"

    struct Release { let version: String; let notes: String; let zip: URL }

    var pending: Release?
    var timer: Timer?
    var window: NSWindow?
    var installing = false
    /// Set by the app: whether its main window is on screen, so a found update can open its window right away.
    var mainWindowVisible: () -> Bool = { false }

    var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    var skipped: String? {
        get { UserDefaults.standard.string(forKey: "SkippedUpdate") }
        set { UserDefaults.standard.set(newValue, forKey: "SkippedUpdate") }
    }

    /// Compares dotted versions part by part as numbers; a leading "v" is ignored, anything unreadable is never newer.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int]? {
            let p = s.trimmingCharacters(in: .whitespaces).drop(while: { $0 == "v" || $0 == "V" }).split(separator: ".")
            let n = p.compactMap { Int($0) }
            return n.isEmpty || n.count != p.count ? nil : n
        }
        guard let a = parts(candidate), let b = parts(current) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// First check shortly after launch, then every 6 hours.
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.check(manual: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.check(manual: false) }
    }

    @objc func checkNow() { check(manual: true) }

    func check(manual: Bool) {
        var req = URLRequest(url: Self.latestURL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let release = (resp as? HTTPURLResponse)?.statusCode == 200 ? data.flatMap(Self.parse) : nil
            DispatchQueue.main.async { self.found(release, reached: data != nil && (resp as? HTTPURLResponse)?.statusCode == 200, manual: manual) }
        }.resume()
    }

    static func parse(_ data: Data) -> Release? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = j["tag_name"] as? String else { return nil }
        let version = String(tag.drop(while: { $0 == "v" || $0 == "V" }))
        let assets = j["assets"] as? [[String: Any]] ?? []
        guard let zip = assets.first(where: { $0["name"] as? String == "Nexview-\(version).zip" })?["browser_download_url"] as? String,
              let url = URL(string: zip) else { return nil }
        return Release(version: version, notes: j["body"] as? String ?? "", zip: url)
    }

    func found(_ release: Release?, reached: Bool, manual: Bool) {
        guard let r = release, Self.isNewer(r.version, than: current) else {
            if manual { alert(reached ? "You're up to date." : "Could not check for updates.",
                              reached ? "Nexview for Mac \(current) is the newest version." : "GitHub could not be reached. Try again later.") }
            return
        }
        if !manual && r.version == skipped { return }
        pending = r
        if manual || (NSApp.isActive && mainWindowVisible()) { showPending() } else { notify(r) }
    }

    func notify(_ r: Release) {
        let c = UNMutableNotificationContent()
        c.title = "Update available"
        c.body = "Nexview for Mac \(r.version) is ready to install."
        c.userInfo = ["update": r.version]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "nexview-update-\(r.version)", content: c, trigger: nil))
    }

    // MARK: window

    @objc func showPending() {
        guard let r = pending else { return }
        window?.close()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Software Update"
        w.isReleasedWhenClosed = false

        let icon = NSImageView(image: NSApp.applicationIconImage)
        let title = NSTextField(labelWithString: "Nexview for Mac \(r.version) is available")
        title.font = .boldSystemFont(ofSize: 15)
        let sub = NSTextField(labelWithString: "You have version \(current). Here's what's new:")
        sub.textColor = .secondaryLabelColor

        let notes = NSTextView()
        notes.isEditable = false
        notes.textContainerInset = NSSize(width: 8, height: 8)
        notes.textStorage?.setAttributedString(Self.render(r.notes))
        let scroll = NSScrollView()
        scroll.documentView = notes
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        notes.autoresizingMask = [.width]
        notes.isVerticallyResizable = true
        notes.textContainer?.widthTracksTextView = true

        let install = NSButton(title: "Install and Restart", target: self, action: #selector(installPending))
        install.keyEquivalent = "\r"
        let later = NSButton(title: "Later", target: self, action: #selector(later))
        let skip = NSButton(title: "Skip This Version", target: self, action: #selector(skip))

        let head = NSStackView(views: [title, sub]); head.orientation = .vertical; head.alignment = .leading; head.spacing = 4
        let top = NSStackView(views: [icon, head]); top.spacing = 12
        icon.widthAnchor.constraint(equalToConstant: 56).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true
        let buttons = NSStackView(views: [skip, NSView(), later, install])
        let all = NSStackView(views: [top, scroll, buttons])
        all.orientation = .vertical; all.alignment = .leading; all.spacing = 12
        all.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        all.translatesAutoresizingMaskIntoConstraints = false
        w.contentView = NSView()
        w.contentView!.addSubview(all)
        NSLayoutConstraint.activate([
            all.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor),
            all.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor),
            all.topAnchor.constraint(equalTo: w.contentView!.topAnchor),
            all.bottomAnchor.constraint(equalTo: w.contentView!.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: all.widthAnchor, constant: -40),
            buttons.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.center()
        w.makeKeyAndOrderFront(nil)
    }

    /// Release notes are Markdown; show headings, lists, bold and links, falling back to plain text.
    static func render(_ md: String) -> NSAttributedString {
        let text = md.isEmpty ? "No release notes." : md
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        guard let a = try? AttributedString(markdown: text, options: opts) else {
            return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        }
        // .full parsing drops line breaks between blocks; put them back from the block identities.
        let out = NSMutableAttributedString()
        var lastBlock: Int?
        for run in a.runs {
            let block = run.presentationIntent?.components.first?.identity
            let newBlock = block != nil && block != lastBlock
            if newBlock, lastBlock != nil { out.append(NSAttributedString(string: "\n")) }
            lastBlock = block ?? lastBlock
            var piece = String(a[run.range].characters)
            let kinds = run.presentationIntent?.components.map(\.kind) ?? []
            var font = NSFont.systemFont(ofSize: 13)
            if kinds.contains(where: { if case .header = $0 { return true }; return false }) { font = .boldSystemFont(ofSize: 14) }
            if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true { font = .boldSystemFont(ofSize: font.pointSize) }
            if run.inlinePresentationIntent?.contains(.code) == true { font = .monospacedSystemFont(ofSize: 12, weight: .regular) }
            if newBlock, kinds.contains(where: { if case .listItem = $0 { return true }; return false }) { piece = "•  " + piece }
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            let para = NSMutableParagraphStyle()
            para.paragraphSpacingBefore = kinds.contains(where: { if case .listItem = $0 { return true }; return false }) ? 2 : 8
            attrs[.paragraphStyle] = para
            if let link = run.link { attrs[.link] = link }
            out.append(NSAttributedString(string: piece, attributes: attrs))
        }
        return out
    }

    @objc func later() { window?.close() }
    @objc func skip() { skipped = pending?.version; window?.close() }

    // MARK: install

    @objc func installPending() {
        guard let r = pending, !installing else { return }
        installing = true
        let target = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            installing = false
            alert("Could not install the update.", "Nexview can't write to \(target.deletingLastPathComponent().path).")
            return
        }
        window?.title = "Downloading \(r.version)…"
        URLSession.shared.downloadTask(with: r.zip) { file, resp, err in
            let result: Result<URL, Error>
            if let file, (resp as? HTTPURLResponse)?.statusCode == 200 { result = Result { try self.unpack(file, expecting: r.version) } }
            else { result = .failure(UpdateError(err?.localizedDescription ?? "The download failed.")) }
            DispatchQueue.main.async {
                switch result {
                case .success(let app): self.swap(in: app, for: target)
                case .failure(let e):
                    self.installing = false
                    self.window?.title = "Software Update"
                    self.alert("Could not install the update.", (e as? UpdateError)?.text ?? e.localizedDescription)
                }
            }
        }.resume()
    }

    struct UpdateError: Error { let text: String; init(_ t: String) { text = t } }

    /// Unzips next to nothing that matters, then checks it is Nexview for Mac at the expected, newer version.
    func unpack(_ zip: URL, expecting version: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nexview-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path]) else { throw UpdateError("The download could not be unpacked.") }
        let app = dir.appendingPathComponent("Nexview.app")
        guard let b = Bundle(url: app), b.bundleIdentifier == Self.bundleID,
              let v = b.infoDictionary?["CFBundleShortVersionString"] as? String, v == version, Self.isNewer(v, than: current)
        else { throw UpdateError("The download is not a newer Nexview for Mac.") }
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    /// The running app can't replace itself, so a short script waits for it to quit, swaps the bundle and reopens it.
    func swap(in app: URL, for target: URL) {
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        old="$2.old-$$"
        mv "$2" "$old" && { mv "$1" "$2" && rm -rf "$old" || mv "$old" "$2"; }
        open "$2"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", script, "nexview-update", app.path, target.path]
        do { try p.run() } catch {
            installing = false
            alert("Could not install the update.", error.localizedDescription); return
        }
        NSApp.terminate(nil)
    }

    @discardableResult func run(_ tool: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
