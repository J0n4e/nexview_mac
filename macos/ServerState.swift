// Per-address state when a server is edited or removed, and deleting the app's keys on the server.
import Cocoa
import WebKit
import UserNotifications

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
            // LastNotified is keyed per account; also drop the entries of accounts whose old keys are still queued here.
            let queuedUsers = Set((self.pendingKeyDeletions[url] ?? []).compactMap { $0["user"] as? String })
            if !queuedUsers.isEmpty {
                var seen = UserDefaults.standard.dictionary(forKey: "LastNotified") as? [String: Int] ?? [:]
                for u in queuedUsers { seen[Self.notifyTag(url, u)] = nil }
                UserDefaults.standard.set(seen, forKey: "LastNotified")
            }
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
        if let f = pollFailures.removeValue(forKey: old) { pollFailures[new] = f }
        if let t = nextPollAt.removeValue(forKey: old) { nextPollAt[new] = t }
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
        resetBackoff(url)
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
