// Notifications checked by the app itself: polling, Notification Center bookkeeping, queued mark-reads.
import Cocoa
import CryptoKit
import UserNotifications

extension AppDelegate {
    // MARK: notifications, checked by the app itself
    //
    // Every saved server with a read-only access key is asked directly once a minute, so
    // notifications arrive with the window closed and for every server, not just the one on screen.


    func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.pollAll() }
        pollTimer?.tolerance = 10
        pollAll()
    }

    func pollAll() {
        let now = Date()
        for srv in store.servers {
            guard let k = store.apiKeys?[srv.url] else { counts[srv.url] = nil; continue }
            // A server that keeps failing is checked less often (see Backoff); its last count stays.
            if Backoff.isDue(next: nextPollAt[srv.url], now: now) { poll(srv, k) }
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
            if Backoff.isFailure(status: unread.status) { recordPollFailure(srv.url) } else { resetBackoff(srv.url) }
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

    /// Network error or 5xx: wait longer before the next check of this server (60 s, 120 s, 240 s, ... 15 min).
    func recordPollFailure(_ url: String) {
        let n = (pollFailures[url] ?? 0) + 1
        pollFailures[url] = n
        nextPollAt[url] = Date().addingTimeInterval(Backoff.interval(failures: n))
    }

    /// The server answered, or the user opened or reloaded it: back to the normal interval.
    func resetBackoff(_ url: String) {
        pollFailures[url] = nil
        nextPollAt[url] = nil
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
        set {
            UserDefaults.standard.set(Array(newValue.suffix(Self.shownLimit)), forKey: "ShownNotifications")
            watchForClears()
        }
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

    /// macOS does not reliably tell an app when its notifications are cleared from Notification Center,
    /// so look every few seconds: any of ours that vanished without us removing it was cleared by the user.
    /// Runs only while some of ours are in Notification Center (`shown` not empty); called whenever it changes.
    func watchForClears() {
        if shownList.isEmpty { clearTimer?.invalidate(); clearTimer = nil; return }
        guard clearTimer == nil else { return }
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


    func flushReads() {
        guard let srv = store.current, let ids = pendingReads[srv.url], !ids.isEmpty, !readsInFlight.contains(srv.url) else { return }
        readsInFlight.insert(srv.url)
        webView.evaluateJavaScript("window.__nexviewMacMarkRead && window.__nexviewMacMarkRead(\(ids))", completionHandler: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.readsInFlight.remove(srv.url) }
    }

    func updateBadge() { setBadge(store.servers.reduce(0) { $0 + (counts[$1.url] ?? 0) }) }

    // MARK: Dock badge + notifications
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

    /// Key for per-account state in prefs (LastNotified), hashed so neither server nor username is readable there.
    static func notifyTag(_ server: String, _ user: String) -> String {
        SHA256.hash(data: Data("\(user)@\(server)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
