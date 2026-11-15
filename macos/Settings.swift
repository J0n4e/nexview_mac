// Native Settings and About windows (SwiftUI, hosted in AppKit windows).
import Cocoa
import SwiftUI
import UserNotifications
import WebKit

// MARK: preferences (no secrets here; servers and access keys live in store.json, see Store.swift)

enum Prefs {
    static let d = UserDefaults.standard
    static func bool(_ k: String, default def: Bool = true) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
    static var notifications: Bool { bool("NotificationsEnabled") }
    static var sound: Bool { bool("NotificationSound") }
    static var badge: Bool { bool("DockBadge") }
    static var keepRunning: Bool { bool("KeepRunning") }
    static var openAtLogin: Bool { bool("OpenAtLogin", default: false) }
}

enum AppInfo {
    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?" }
    static var sourceVersion: String { Bundle.main.infoDictionary?["NexviewSourceVersion"] as? String ?? "?" }
    static let repo = URL(string: "https://github.com/DerKezorm/nexview")!
    static let developer = URL(string: "https://github.com/DerKezorm")!
    static let macRepo = URL(string: "https://github.com/J0n4e/nexview_mac")!
}

// MARK: model shared by both windows

enum Health: Equatable { case unknown, checking, online(String), offline(String) }

final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()
    var app: AppDelegate { NSApp.delegate as! AppDelegate }

    @Published var servers: [Server] = []
    @Published var selected = 0
    @Published var health: [String: Health] = [:]

    func refresh() {
        servers = app.store.servers
        selected = app.store.selected
    }

    func checkAll() { servers.forEach { check($0.url) } }

    func check(_ url: String) {
        health[url] = .checking
        Self.probe(url) { r in self.health[url] = r }
    }

    /// Asks a server for /api/health; reports the Nexview version it runs.
    static func probe(_ url: String, done: @escaping (Health) -> Void) {
        guard let u = URL(string: url)?.appendingPathComponent("api/health") else { done(.offline("Invalid address")); return }
        var req = URLRequest(url: u); req.timeoutInterval = 8; req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { data, resp, err in
            var result = Health.offline(err?.localizedDescription ?? "Not a Nexview server")
            if (resp as? HTTPURLResponse)?.statusCode == 200, let data,
               let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], j["status"] != nil {
                result = .online(j["version"] as? String ?? "?")
            }
            DispatchQueue.main.async { done(result) }
        }.resume()
    }

    func activate(_ i: Int) { app.selectServer(i); refresh() }

    /// Returns an error to show inline (e.g. the address is already used by another server), or nil when saved.
    func save(_ srv: Server, at i: Int?) -> String? {
        if let i {
            let active = i == app.store.selected
            if let err = app.editServer(at: i, srv, then: { [self] in
                if active { app.loadServer() }
                app.buildMenu(); refresh(); check(srv.url)
            }) { return err }
        } else {
            guard app.store.add(srv) else { return app.duplicateError(srv.url, except: nil) ?? "This address is already added." }
            app.loadServer(); app.buildMenu(); refresh(); check(srv.url)
        }
        return nil
    }

    /// Error for an address that another server (not `except`) already uses.
    func duplicateError(_ url: String, except: Int?) -> String? { app.duplicateError(url, except: except) }

    func remove(_ i: Int) {
        let wasActive = i == app.store.selected
        // Deletes the key on the server first when this server is the page on screen (best effort).
        app.removeServer(at: i) { [self] in
            if app.store.current == nil { app.webView.loadHTMLString("", baseURL: nil); app.window.title = "Nexview" }
            else if wasActive { app.loadServer() }
            app.buildMenu(); refresh()
        }
    }

    func move(_ from: IndexSet, _ to: Int) { app.store.move(from: from, to: to); app.buildMenu(); refresh() }
}

/// Local view state without the @State macro (the command-line toolchain lacks SwiftUI's macro plugin).
final class Box<T>: ObservableObject {
    @Published var v: T
    init(_ v: T) { self.v = v }
}

// MARK: Settings

enum Pane: String, CaseIterable, Identifiable {
    case servers = "Servers", notifications = "Notifications", general = "General"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .servers: "server.rack"; case .notifications: "bell"; case .general: "gearshape" }
    }
}

struct SettingsView: View {
    @ObservedObject var model = SettingsModel.shared
    @StateObject private var pane = Box<Pane>(.servers)
    @StateObject private var hover = Box<Pane?>(nil)

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(NX.ink700).frame(height: 1)
            ScrollView {
                Group {
                    switch pane.v {
                    case .servers: ServersPane()
                    case .notifications: NotificationsPane()
                    case .general: GeneralPane()
                    }
                }
                .padding(24)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
        }
        .background(NX.ink950)
        .ignoresSafeArea(.container, edges: .top)   // top bar shares the row with the window buttons
        .preferredColorScheme(.dark)
        .focusEffectDisabled()   // no blue focus rings; Nexview has none
        .frame(minWidth: 760, minHeight: 520)
        .onAppear { model.refresh(); model.checkAll() }
    }

    var topBar: some View {
        HStack(spacing: 22) {
            Wordmark()
            Text("Settings").font(.system(size: 13, weight: .medium)).foregroundColor(NX.mist500)
                .padding(.leading, -10)
            Spacer()
            HStack(spacing: 4) {
                ForEach(Pane.allCases) { p in
                    let active = p == pane.v
                    Button { withAnimation(.easeOut(duration: 0.15)) { pane.v = p } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: p.symbol).font(.system(size: 12, weight: .semibold))
                            Text(p.rawValue).font(.system(size: 13, weight: active ? .semibold : .medium))
                        }
                        .foregroundColor(active ? NX.mist100 : (hover.v == p ? NX.mist300 : NX.mist500))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(active ? NX.ink800 : .clear))
                        .overlay(alignment: .bottom) {
                            if active { Capsule().fill(NX.gradient).frame(width: 22, height: 2.5).offset(y: 9) }
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .onHover { hover.v = $0 ? p : (hover.v == p ? nil : hover.v) }
                }
            }
        }
        .padding(.leading, 86)      // room for the window's traffic lights
        .padding(.trailing, 18)
        .frame(height: 54)
        .background(NX.ink950)
    }
}

struct ServersPane: View {
    @ObservedObject var model = SettingsModel.shared
    @StateObject private var editing = Box<EditTarget?>(nil)
    @StateObject private var confirmRemove = Box<Int?>(nil)

    struct EditTarget: Identifiable { let id = UUID(); let index: Int?; let server: Server }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Your servers", "Every Nexview you connect to.") {
                Button { editing.v = EditTarget(index: nil, server: Server(name: "", url: "")) } label: {
                    Label("Add server", systemImage: "plus")
                }.buttonStyle(NXButton(kind: .primary))
            }
            if model.servers.isEmpty {
                Card {
                    VStack(spacing: 10) {
                        Image(systemName: "server.rack").font(.system(size: 30)).foregroundColor(NX.mist600)
                        Text("No servers yet").font(.headline).foregroundColor(NX.mist100)
                        Text("Add the address of your Nexview server to get started.").foregroundColor(NX.mist500)
                    }.frame(maxWidth: .infinity).padding(.vertical, 20)
                }
            }
            ForEach(Array(model.servers.enumerated()), id: \.element.url) { i, srv in row(i, srv) }
            if !model.servers.isEmpty {
                HStack {
                    Spacer()
                    Button { model.checkAll() } label: { Label("Check all", systemImage: "arrow.clockwise") }
                        .buttonStyle(NXButton())
                }
            }
        }
        .sheet(item: $editing.v) { t in ServerEditor(index: t.index, server: t.server) }
        .alert("Remove this server?", isPresented: Binding(get: { confirmRemove.v != nil }, set: { if !$0 { confirmRemove.v = nil } })) {
            Button("Remove", role: .destructive) { if let i = confirmRemove.v { model.remove(i) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its address and the app’s read-only access key will be deleted from this Mac.")
        }
    }

    func row(_ i: Int, _ srv: Server) -> some View {
        let active = i == model.selected
        return HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(active ? AnyShapeStyle(NX.gradient) : AnyShapeStyle(NX.ink800))
                Image(systemName: "server.rack").font(.system(size: 17, weight: .semibold)).foregroundColor(active ? .white : NX.mist500)
            }
            .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(srv.name).font(.system(size: 15, weight: .semibold)).foregroundColor(NX.mist100)
                    if active {
                        Text("CONNECTED").font(.system(size: 9, weight: .bold)).tracking(0.8)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(NX.accent500.opacity(0.18)))
                            .foregroundColor(NX.accent300)
                    }
                }
                Text(srv.url).font(.system(size: 12)).foregroundColor(NX.mist500).textSelection(.enabled)
                StatusDot(health: model.health[srv.url] ?? .unknown)
            }
            Spacer()
            if !active { Button("Connect") { model.activate(i) }.buttonStyle(NXButton(kind: .primary)) }
            Button { editing.v = EditTarget(index: i, server: srv) } label: { Image(systemName: "pencil") }
                .buttonStyle(NXButton()).help("Edit")
            Menu {
                Button("Check Connection") { model.check(srv.url) }
                Button("Open in Browser") { if let u = URL(string: srv.url) { NSWorkspace.shared.open(u) } }
                Divider()
                Button("Remove…", role: .destructive) { confirmRemove.v = i }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .bold)).foregroundColor(NX.mist300)
                    .frame(width: 32, height: 30)
                    .background(RoundedRectangle(cornerRadius: 9).fill(NX.ink800))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(NX.ink700, lineWidth: 1))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(NX.ink850))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(active ? NX.accent500.opacity(0.45) : NX.ink700, lineWidth: 1))
    }
}

/// Page heading in Nexview's style: big bold title with the red full stop.
func header<Trailing: View>(_ title: String, _ sub: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) -> some View {
    HStack(alignment: .bottom) {
        VStack(alignment: .leading, spacing: 4) {
            (Text(title).foregroundColor(NX.mist100) + Text(".").foregroundColor(NX.accent500))
                .font(.system(size: 26, weight: .bold))
            Text(sub).font(.system(size: 13)).foregroundColor(NX.mist500)
        }
        Spacer()
        trailing()
    }
    .padding(.bottom, 4)
}

struct ServerEditor: View {
    let index: Int?
    @StateObject private var server: Box<Server>
    @Environment(\.dismiss) private var dismiss
    @StateObject private var result = Box<Health>(.unknown)

    init(index: Int?, server: Server) { self.index = index; _server = StateObject(wrappedValue: Box(server)) }

    var normalised: URL? { ServerURL.parse(server.v.url) }
    var duplicate: String? { normalised.flatMap { SettingsModel.shared.duplicateError($0.absoluteString, except: index) } }
    @StateObject private var saveError = Box<String?>(nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header(index == nil ? "Add server" : "Edit server", "Your Nexview server, e.g. on Unraid")
            NXField(label: "Name", placeholder: "Home", text: $server.v.name)
            NXField(label: "Address", placeholder: "https://nexview.example.com", text: $server.v.url)
                .onChange(of: server.v.url) { result.v = .unknown; saveError.v = nil }
            if let err = duplicate ?? saveError.v {
                Label(err, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .medium)).foregroundColor(NX.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let u = normalised, AppDelegate.isInsecureRemote(u) {
                Label(AppDelegate.insecureWarning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium)).foregroundColor(NX.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button("Test connection") { test() }.buttonStyle(NXButton()).disabled(normalised == nil)
                switch result.v {
                case .checking: ProgressView().controlSize(.small)
                case .online(let v): Label("Nexview \(v) is reachable", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium)).foregroundColor(NX.ok)
                case .offline(let e): Label(e, systemImage: "xmark.octagon.fill")
                    .font(.system(size: 12, weight: .medium)).foregroundColor(NX.bad).lineLimit(2)
                case .unknown: EmptyView()
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(NXButton()).keyboardShortcut(.cancelAction)
                Button(index == nil ? "Add server" : "Save") { saveIfReachable() }
                    .buttonStyle(NXButton(kind: .primary)).keyboardShortcut(.defaultAction)
                    .disabled(normalised == nil || duplicate != nil || result.v == .checking)
            }
            .padding(.top, 6)
        }
        .padding(26)
        .frame(width: 480)
        .background(NX.ink900)
        .preferredColorScheme(.dark)
        .focusEffectDisabled()   // no blue focus rings; Nexview has none
    }

    func test(then: ((Bool) -> Void)? = nil) {
        guard let u = normalised else { return }
        result.v = .checking
        SettingsModel.probe(u.absoluteString) { r in
            result.v = r
            if case .online = r { then?(true) } else { then?(false) }
        }
    }

    func saveIfReachable() {
        test { ok in
            guard ok, let u = normalised else { return }
            let name = server.v.name.trimmingCharacters(in: .whitespaces)
            if let err = SettingsModel.shared.save(Server(name: name.isEmpty ? (u.host ?? "Server") : name, url: u.absoluteString), at: index) {
                saveError.v = err; return
            }
            dismiss()
        }
    }
}

struct NotificationsPane: View {
    @AppStorage("NotificationsEnabled") var notifications = true
    @AppStorage("NotificationSound") var sound = true
    @AppStorage("DockBadge") var badge = true
    @AppStorage("KeepRunning") var background = true
    @AppStorage("OpenAtLogin") var openAtLogin = false
    @StateObject private var status = Box<UNAuthorizationStatus>(.notDetermined)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Notifications", "Know when something is ready, approved or waiting for you.")
            Card {
                NXToggleRow(title: "Show notifications", detail: "Ready to watch, approvals, declined requests, tickets", isOn: $notifications)
                Rectangle().fill(NX.ink700).frame(height: 1)
                NXToggleRow(title: "Play sound", isOn: $sound).disabled(!notifications).opacity(notifications ? 1 : 0.45)
                Rectangle().fill(NX.ink700).frame(height: 1)
                NXToggleRow(title: "Badge on the Dock icon", detail: "Unread notifications plus requests waiting for your approval", isOn: $badge)
                    .onChange(of: badge) { let a = NSApp.delegate as! AppDelegate; a.setBadge(a.lastBadge) }
            }
            Card {
                NXToggleRow(title: "Run in background",
                            detail: background
                                ? "Closing the window leaves Nexview running with only an icon in the menu bar, so notifications still arrive. Click that icon to bring it back; ⌘Q quits completely."
                                : "Closing the window quits Nexview. You only get notifications while its window is open.",
                            isOn: $background)
                    .onChange(of: background) { (NSApp.delegate as? AppDelegate)?.applyBackgroundMode() }
                Rectangle().fill(NX.ink700).frame(height: 1)
                NXToggleRow(title: "Open at login",
                            detail: openAtLogin
                                ? "Nexview starts when you log in to your Mac, so you don’t miss notifications after a restart."
                                : "Nexview only starts when you open it yourself.",
                            isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { (NSApp.delegate as? AppDelegate)?.applyLoginItem() }
            }
            Card(title: "macOS permission") {
                HStack(spacing: 10) {
                    switch status.v {
                    case .authorized, .provisional: Label("Allowed", systemImage: "checkmark.circle.fill").foregroundColor(NX.ok)
                    case .denied: Label("Blocked in System Settings", systemImage: "xmark.circle.fill").foregroundColor(NX.bad)
                    default: Text("Not asked yet").foregroundColor(NX.mist500)
                    }
                    Spacer()
                    Button("Send test") { test() }.buttonStyle(NXButton()).disabled(!notifications)
                    Button("System Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }.buttonStyle(NXButton())
                }
                .font(.system(size: 13, weight: .medium))
            }
        }
        .onAppear { refreshStatus() }
    }

    func refreshStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { s in DispatchQueue.main.async { status.v = s.authorizationStatus } }
    }

    func test() {
        let c = UNMutableNotificationContent()
        c.title = "Nexview"; c.body = "Notifications are working."; c.sound = sound ? .default : nil
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "nexview-test-\(Date().timeIntervalSince1970)", content: c, trigger: nil))
        refreshStatus()
    }
}

struct GeneralPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("General", "How the app behaves on this Mac.")
            Card(title: "Website data") {
                actionRow("Clear cache", "Reloads Nexview from the server. You stay signed in.", "Clear cache", .secondary) {
                    WKWebsiteDataStore.default().removeData(ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache],
                                                            modifiedSince: .distantPast) { (NSApp.delegate as? AppDelegate)?.loadServer() }
                }
                Rectangle().fill(NX.ink700).frame(height: 1)
                actionRow("Sign out everywhere in this app", "Removes all cookies and stored website data.", "Reset", .danger) {
                    let wipe = {
                        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                                                modifiedSince: .distantPast) { (NSApp.delegate as? AppDelegate)?.loadServer() }
                    }
                    // Delete the app's keys on the servers (the current one through the page, before its session goes).
                    if let app = NSApp.delegate as? AppDelegate { app.forgetAllKeys(then: wipe) } else { wipe() }
                }
            }
        }
    }

    func actionRow(_ t: String, _ d: String, _ b: String, _ k: NXButton.Kind, _ action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(t).font(.system(size: 13, weight: .medium)).foregroundColor(NX.mist100)
                Text(d).font(.system(size: 12)).foregroundColor(NX.mist500)
            }
            Spacer()
            Button(b, action: action).buttonStyle(NXButton(kind: k))
        }
    }
}

// MARK: About

struct AboutView: View {
    @ObservedObject var model = SettingsModel.shared
    @StateObject private var serverVersion = Box<Health>(.unknown)

    var body: some View {
        VStack(spacing: 0) {
            // Icon and name on one line keeps the window compact.
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                    .shadow(color: NX.accent500.opacity(0.45), radius: 16, y: 4)
                VStack(alignment: .leading, spacing: 2) {
                    (Text("NEX").foregroundColor(NX.mist100) + Text("VIEW").foregroundColor(NX.accent400))
                        .font(.system(size: 30, weight: .heavy))
                    Text("for Mac").font(.system(size: 13)).foregroundColor(NX.mist500)
                }
            }
            .padding(.top, 34).padding(.bottom, 20)

            VStack(spacing: 0) {
                infoRow("App version", AppInfo.appVersion)
                Rectangle().fill(NX.ink700).frame(height: 1)
                infoRow("Nexview on \(model.servers.indices.contains(model.selected) ? model.servers[model.selected].name : "server")", serverText)
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(NX.ink850))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(NX.ink700, lineWidth: 1))
            .padding(.horizontal, 28)

            VStack(spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "heart.fill").foregroundColor(NX.accent400)
                    (Text("Thank you, DerKezorm").foregroundColor(NX.mist100) + Text(".").foregroundColor(NX.accent500))
                        .font(.system(size: 16, weight: .bold))
                }
                Text("Nexview is created and maintained by DerKezorm. This Mac app is just a native window around their work — every feature you use comes from Nexview.")
                    .multilineTextAlignment(.center).font(.system(size: 13)).foregroundColor(NX.mist500)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button { NSWorkspace.shared.open(AppInfo.repo) } label: {
                        Label("Nexview on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }.buttonStyle(NXButton(kind: .primary))
                    Button { NSWorkspace.shared.open(AppInfo.repo.appendingPathComponent("issues")) } label: {
                        Label("Report an issue", systemImage: "exclamationmark.bubble")
                    }.buttonStyle(NXButton())
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, 34).padding(.top, 24)

            // The Mac app itself, laid out exactly like the developer's section above.
            VStack(spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "laptopcomputer").foregroundColor(NX.accent400)
                    (Text("Nexview for Mac").foregroundColor(NX.mist100) + Text(".").foregroundColor(NX.accent500))
                        .font(.system(size: 16, weight: .bold))
                }
                Text("The Mac version of Nexview. Found a bug or have an idea? Let us know on GitHub.")
                    .multilineTextAlignment(.center).font(.system(size: 13)).foregroundColor(NX.mist500)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button { NSWorkspace.shared.open(AppInfo.macRepo) } label: {
                        Label("Mac app on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }.buttonStyle(NXButton(kind: .primary))
                    Button { NSWorkspace.shared.open(AppInfo.macRepo.appendingPathComponent("issues")) } label: {
                        Label("Report an issue", systemImage: "exclamationmark.bubble")
                    }.buttonStyle(NXButton())
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, 34).padding(.top, 24)

            Text("Nexview © 2026 DerKezorm · GNU AGPL-3.0")
                .font(.system(size: 10)).foregroundColor(NX.mist600).padding(.vertical, 20)
        }
        .frame(width: 440)
        .background(NX.ink950)
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
        .focusEffectDisabled()   // no blue focus rings; Nexview has none
        .onAppear {
            model.refresh()
            if let u = (NSApp.delegate as? AppDelegate)?.serverURL {
                serverVersion.v = .checking
                SettingsModel.probe(u.absoluteString) { serverVersion.v = $0 }
            }
        }
    }

    var serverText: String {
        switch serverVersion.v {
        case .online(let v): v
        case .checking: "…"
        case .offline: "unreachable"
        case .unknown: "—"
        }
    }

    func infoRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 13)).foregroundColor(NX.mist500)
            Spacer()
            Text(v).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundColor(NX.mist100).textSelection(.enabled)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }
}

// MARK: windows

final class PanelWindows {
    static var settings: NSWindow?
    static var about: NSWindow?

    static func make<V: View>(_ view: V, title: String) -> NSWindow {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.minSize]
        let w = NSWindow(contentViewController: host)
        w.title = title
        w.isReleasedWhenClosed = false
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(red: 0x0b / 255, green: 0x0b / 255, blue: 0x0f / 255, alpha: 1)
        w.isMovableByWindowBackground = true
        return w
    }

    /// With the main window closed, closing Settings or About also hides the Dock icon again.
    static let closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { n in
        guard let w = n.object as? NSWindow, w === settings || w === about,
              let app = NSApp.delegate as? AppDelegate, Prefs.keepRunning, !app.window.isVisible else { return }
        let others = [settings, about].compactMap { $0 }.filter { $0 !== w && $0.isVisible }
        if others.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }

    /// Opens the window exactly in the middle of the screen the main window is on.
    static func present(_ w: NSWindow) {
        _ = closeObserver
        NSApp.setActivationPolicy(.regular)
        if !w.isVisible {
            // Size the window from its SwiftUI content before it appears, so it shows once, already centred.
            if let host = w.contentViewController as? NSHostingController<AboutView> {
                w.setContentSize(host.sizeThatFits(in: NSSize(width: 440, height: 10_000)))
            }
            center(w)
        }
        w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    static func center(_ w: NSWindow) {
        guard let screen = (NSApp.delegate as? AppDelegate)?.window?.screen ?? NSScreen.main else { return }
        let v = screen.visibleFrame, f = w.frame
        w.setFrameOrigin(NSPoint(x: (v.midX - f.width / 2).rounded(), y: (v.midY - f.height / 2).rounded()))
    }

    static func showSettings() {
        if settings == nil {
            let w = make(SettingsView(), title: "Settings")
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.setContentSize(NSSize(width: 860, height: 680))
            w.center()
            settings = w
        }
        present(settings!)
    }

    static func showAbout() {
        if about == nil {
            let w = make(AboutView(), title: "About Nexview")
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.center()
            about = w
        }
        present(about!)
    }
}
