import AppKit
import CryptoKit
import Security
import UserNotifications

/// Looks for new releases of Nexview for Mac on GitHub and, when asked, installs one and restarts.
/// The app is built without Xcode and not notarized, so this is a small updater of its own, not Sparkle.
final class Updater: NSObject {
    static let shared = Updater()
    static let latestURL = URL(string: "https://api.github.com/repos/J0n4e/nexview_mac/releases/latest")!
    static let bundleID = "io.github.derkezorm.nexview.macos"
    /// Release assets are only ever fetched from this repo's GitHub release downloads.
    static let downloadPrefix = "https://github.com/J0n4e/nexview_mac/releases/download/"
    /// Ed25519 public key (raw 32 bytes, base64) whose private half signs every release zip.
    /// The app is self-signed (not notarized), so this signature is the real trust anchor for updates.
    static let signingPublicKey = "QZNsnKHonvP62BxLWUxBUfej1aqt65ao2TeYBEeZNKk="

    /// `zip`/`sig` are nil when the release exists but lacks a usable asset.
    struct Release { let version: String; let notes: String; let zip: URL?; let sig: URL? }

    var pending: Release?
    var timer: Timer?
    var window: NSWindow?
    var installing = false
    var installButtons: [NSButton] = []
    var progressBar: NSProgressIndicator?
    var statusLabel: NSTextField?
    var progressObservation: NSKeyValueObservation?
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
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let http = resp as? HTTPURLResponse
            let status = Self.classifyCheck(statusCode: http?.statusCode,
                                            rateLimitRemaining: http?.value(forHTTPHeaderField: "X-RateLimit-Remaining"),
                                            transportFailed: err != nil || data == nil)
            let release = status == .ok ? data.flatMap(Self.parse) : nil
            DispatchQueue.main.async { self.found(release, status: status, manual: manual) }
        }.resume()
    }

    /// Why a release check did or didn't get an answer from GitHub.
    enum CheckStatus: Equatable { case ok, rateLimited, offline, serverError(Int) }

    /// Pure classification of a check response, so a GitHub rate limit isn't reported as being offline.
    static func classifyCheck(statusCode: Int?, rateLimitRemaining: String?, transportFailed: Bool) -> CheckStatus {
        guard let code = statusCode, code > 0 else { return .offline }
        if transportFailed && code == 200 { return .offline }
        if code == 200 { return .ok }
        if code == 429 { return .rateLimited }
        if code == 403, rateLimitRemaining?.trimmingCharacters(in: .whitespaces) == "0" { return .rateLimited }
        return .serverError(code)
    }

    static func checkFailureText(_ s: CheckStatus) -> String {
        switch s {
        case .ok: return ""
        case .rateLimited: return "GitHub is limiting how often updates can be checked from your network. Try again in an hour."
        case .offline: return "GitHub could not be reached. Check your internet connection and try again."
        case .serverError(let c): return "GitHub answered with an error (HTTP \(c)). Try again later."
        }
    }

    static func parse(_ data: Data) -> Release? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = j["tag_name"] as? String else { return nil }
        let version = String(tag.drop(while: { $0 == "v" || $0 == "V" }))
        let assets = j["assets"] as? [[String: Any]] ?? []
        func asset(_ name: String) -> URL? {
            guard let s = assets.first(where: { $0["name"] as? String == name })?["browser_download_url"] as? String,
                  s.hasPrefix(downloadPrefix), let u = URL(string: s), u.scheme == "https", u.host == "github.com" else { return nil }
            return u
        }
        return Release(version: version, notes: j["body"] as? String ?? "",
                       zip: asset("Nexview-\(version).zip"), sig: asset("Nexview-\(version).zip.sig"))
    }

    /// True if `signatureBase64` is a valid Ed25519 signature over exactly `data` by the raw 32-byte key `publicKeyBase64`.
    static func verifySignature(data: Data, signatureBase64: String, publicKeyBase64: String) -> Bool {
        guard let keyData = Data(base64Encoded: publicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              let sig = Data(base64Encoded: signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              sig.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { return false }
        return key.isValidSignature(sig, for: data)
    }

    func found(_ release: Release?, status: CheckStatus, manual: Bool) {
        let reached = status == .ok
        if installing { return }
        if let r = release, Self.isNewer(r.version, than: current), r.zip == nil || r.sig == nil {
            if manual { alert("Could not check for updates.",
                              "Nexview for Mac \(r.version) was released, but its download or signature is missing. Try again later.") }
            return
        }
        guard let r = release, Self.isNewer(r.version, than: current) else {
            if manual { alert(reached ? "You're up to date." : "Could not check for updates.",
                              reached ? "Nexview for Mac \(current) is the newest version." : Self.checkFailureText(status)) }
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
        guard !installing, let r = pending else { return }
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
        installButtons = [install, later, skip]
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = true
        bar.minValue = 0; bar.maxValue = 1
        bar.isHidden = true
        let status = NSTextField(wrappingLabelWithString: "")
        status.textColor = .secondaryLabelColor
        status.isHidden = true
        progressBar = bar; statusLabel = status
        let all = NSStackView(views: [top, scroll, bar, status, buttons])
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
            bar.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            status.widthAnchor.constraint(equalTo: scroll.widthAnchor),
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
            if let link = run.link, link.scheme?.lowercased() == "https" { attrs[.link] = link }
            out.append(NSAttributedString(string: piece, attributes: attrs))
        }
        return out
    }

    @objc func later() { window?.close() }
    @objc func skip() { skipped = pending?.version; window?.close() }

    // MARK: install

    @objc func installPending() {
        guard let r = pending, !installing else { return }
        guard let zipURL = r.zip, let sigURL = r.sig else {
            alert("Could not install the update.", "This release has no signed download."); return
        }
        let target = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            installFailed("Nexview can't write to \(target.deletingLastPathComponent().path).")
            return
        }
        setInstalling(true, status: "Downloading \(r.version)…")
        window?.title = "Downloading \(r.version)…"
        let fail: (Error) -> Void = { e in
            DispatchQueue.main.async { self.installFailed((e as? UpdateError)?.text ?? e.localizedDescription) }
        }
        URLSession.shared.dataTask(with: sigURL) { sigData, sigResp, sigErr in
            guard let sigData, (sigResp as? HTTPURLResponse)?.statusCode == 200,
                  let sigText = String(data: sigData, encoding: .utf8) else {
                return fail(UpdateError(sigErr?.localizedDescription ?? "The update's signature could not be downloaded."))
            }
            let task = URLSession.shared.downloadTask(with: zipURL) { file, resp, err in
                DispatchQueue.main.async { self.progressObservation = nil }
                guard let file, (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    return fail(UpdateError(err?.localizedDescription ?? "The download failed."))
                }
                // The temp file is deleted when this handler returns, so move it somewhere we own first.
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nexview-update-\(UUID().uuidString)")
                let zip = dir.appendingPathComponent("Nexview.zip")
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: file, to: zip)
                } catch {
                    try? FileManager.default.removeItem(at: dir)
                    return fail(error)
                }
                // Verification and unpacking run off the main thread; only UI hops back.
                DispatchQueue.main.async {
                    self.progressBar?.isIndeterminate = true
                    self.progressBar?.startAnimation(nil)
                    self.statusLabel?.stringValue = "Verifying \(r.version)…"
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let app = try self.verifyAndUnpack(zip, signature: sigText, into: dir, expecting: r.version)
                        DispatchQueue.main.async { self.swap(in: app, for: target, cleaning: dir) }
                    } catch {
                        try? FileManager.default.removeItem(at: dir)
                        fail(error)
                    }
                }
            }
            DispatchQueue.main.async { self.observeProgress(of: task) }
            task.resume()
        }.resume()
    }

    /// Determinate once the server's Content-Length is known, indeterminate until then.
    func observeProgress(of task: URLSessionDownloadTask) {
        progressObservation = task.progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, let bar = self.progressBar, self.installing else { return }
                let expected = task.countOfBytesExpectedToReceive
                if expected > 0 {
                    if bar.isIndeterminate { bar.stopAnimation(nil); bar.isIndeterminate = false }
                    bar.doubleValue = Double(task.countOfBytesReceived) / Double(expected)
                    self.statusLabel?.stringValue = "Downloading… " + ByteCountFormatter.string(fromByteCount: task.countOfBytesReceived, countStyle: .file)
                        + " of " + ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
                }
            }
        }
    }

    /// Shows or hides the progress UI and locks the window's buttons while an install is running.
    func setInstalling(_ on: Bool, status: String) {
        installing = on
        installButtons.forEach { $0.isEnabled = !on }
        if let bar = progressBar {
            bar.isHidden = !on
            bar.isIndeterminate = true
            if on { bar.startAnimation(nil) } else { bar.stopAnimation(nil) }
        }
        statusLabel?.stringValue = status
        statusLabel?.textColor = .secondaryLabelColor
        statusLabel?.isHidden = status.isEmpty
    }

    /// Unlocks the window and shows the error in it (or in an alert if the window is gone).
    func installFailed(_ text: String) {
        progressObservation = nil
        setInstalling(false, status: "")
        window?.title = "Software Update"
        if let label = statusLabel, let w = window, w.isVisible {
            label.stringValue = "Could not install the update. " + text
            label.textColor = .systemRed
            label.isHidden = false
        } else {
            alert("Could not install the update.", text)
        }
    }

    struct UpdateError: Error { let text: String; init(_ t: String) { text = t } }

    /// Checks the Ed25519 signature over the exact zip bytes before touching its contents, then unzips it
    /// and checks it is a validly code-signed Nexview for Mac at the expected, newer version.
    func verifyAndUnpack(_ zip: URL, signature: String, into dir: URL, expecting version: String) throws -> URL {
        guard let bytes = try? Data(contentsOf: zip),
              Self.verifySignature(data: bytes, signatureBase64: signature, publicKeyBase64: Self.signingPublicKey) else {
            throw UpdateError("The download's signature is missing or invalid, so it was not installed.")
        }
        let out = dir.appendingPathComponent("unpacked")
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path]) else { throw UpdateError("The download could not be unpacked.") }
        let app = out.appendingPathComponent("Nexview.app")
        guard let b = Bundle(url: app), b.bundleIdentifier == Self.bundleID,
              let v = b.infoDictionary?["CFBundleShortVersionString"] as? String, v == version, Self.isNewer(v, than: current)
        else { throw UpdateError("The download is not a newer Nexview for Mac.") }
        // Proves the bundle is intact and internally consistent; the Ed25519 check above is what
        // establishes that it came from us.
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) else {
            throw UpdateError("The downloaded app failed its code signature check.")
        }
        // When this app is signed with the Nexview certificate, the new one must satisfy the same designated
        // requirement, so the Keychain keeps trusting it. Skipped for ad-hoc builds (e.g. updating from 0.1.4).
        guard Self.satisfiesDesignatedRequirement(of: Bundle.main.bundleURL, candidate: app) else {
            throw UpdateError("The downloaded app is not signed with the Nexview for Mac certificate.")
        }
        // No quarantine stripping: URLSession downloads aren't quarantined (no LSFileQuarantineEnabled).
        return app
    }

    /// True if `running` is ad-hoc signed or unsigned (nothing to pin), or if `candidate` satisfies
    /// `running`'s designated requirement.
    static func satisfiesDesignatedRequirement(of running: URL, candidate: URL) -> Bool {
        var cur: SecStaticCode?
        guard SecStaticCodeCreateWithPath(running as CFURL, [], &cur) == errSecSuccess, let cur else { return true }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(cur, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate], !certs.isEmpty
        else { return true } // ad-hoc or unsigned: no certificate to pin
        var req: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(cur, [], &req) == errSecSuccess, let req else { return false }
        var new: SecStaticCode?
        guard SecStaticCodeCreateWithPath(candidate as CFURL, [], &new) == errSecSuccess, let new else { return false }
        return SecStaticCodeCheckValidity(new, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), req) == errSecSuccess
    }

    static var updateLogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Nexview/update.log")
    }

    /// Runs under `zsh -c` after the app quits. Everything comes in as positional arguments, never interpolated:
    /// $1 new app, $2 installed app, $3 temp dir, $4 expected bundle id, $5 expected version, $6 log file, $7 app pid.
    /// It re-checks the new bundle right before the swap, keeps the old bundle at "$2.old" until the new one
    /// has opened, and puts the old one back and reopens it if anything fails.
    static let swapScript = """
    new="$1"; target="$2"; tmp="$3"; want_id="$4"; want_ver="$5"; log="$6"; pid="$7"
    backup="$target.old"
    /bin/mkdir -p "$(/usr/bin/dirname "$log")"
    if [ -f "$log" ] && [ "$(/usr/bin/stat -f %z "$log" 2>/dev/null || echo 0)" -gt 262144 ]; then /bin/mv -f "$log" "$log.1"; fi
    say() { print -r -- "$(/bin/date '+%Y-%m-%d %H:%M:%S') $*" >> "$log" }
    abort() { say "ABORT: $*; keeping the installed app"; /bin/rm -rf "$tmp"; /usr/bin/open "$target"; exit 1 }
    say "update to $want_ver: waiting for pid $pid to quit"
    while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
    /usr/bin/codesign --verify --deep --strict "$new" >> "$log" 2>&1 || abort "codesign verification of the new app failed"
    got_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$new/Contents/Info.plist" 2>/dev/null)"
    [ "$got_id" = "$want_id" ] || abort "bundle id is '$got_id', expected '$want_id'"
    got_ver="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$new/Contents/Info.plist" 2>/dev/null)"
    [ "$got_ver" = "$want_ver" ] || abort "version is '$got_ver', expected '$want_ver'"
    say "new app verified"
    /bin/rm -rf "$backup"
    /bin/mv "$target" "$backup" || abort "could not move the installed app aside"
    if ! /bin/mv "$new" "$target"; then
      /bin/mv "$backup" "$target"
      abort "could not move the new app into place"
    fi
    if /usr/bin/open "$target"; then
      say "opened $want_ver; removing the backup"
      /bin/rm -rf "$backup"
    else
      say "the new app failed to open; restoring the previous one"
      /bin/rm -rf "$target"
      /bin/mv "$backup" "$target" && /usr/bin/open "$target"
    fi
    /bin/rm -rf "$tmp"
    say "done"
    """

    static func swapArguments(app: String, target: String, dir: String, version: String, log: String, pid: Int32) -> [String] {
        ["-c", swapScript, "nexview-update", app, target, dir, bundleID, version, log, String(pid)]
    }

    /// The running app can't replace itself, so a short script waits for it to quit, re-verifies and swaps the bundle and reopens it.
    func swap(in app: URL, for target: URL, cleaning dir: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = Self.swapArguments(app: app.path, target: target.path, dir: dir.path, version: pending?.version ?? "",
                                         log: Self.updateLogURL.path, pid: ProcessInfo.processInfo.processIdentifier)
        do { try p.run() } catch {
            try? FileManager.default.removeItem(at: dir)
            installFailed(error.localizedDescription); return
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
