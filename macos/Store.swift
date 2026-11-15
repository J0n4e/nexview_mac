// Server list and read-only keys in a user-only file (store.json), loading at launch, and the one-time
// migrations from the 0.1.4/0.1.5 Keychain item and the 0.1.3 Secure Enclave vault.
import Foundation
import SwiftUI   // MutableCollection.move(fromOffsets:toOffset:)
import CryptoKit
import Security
import os

// MARK: server list and read-only keys, kept in ~/Library/Application Support/Nexview for Mac/store.json (0600)

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
        guard !StoreFile.writesBlocked else {
            storeLog.error("Not saving: the saved data could not be read at launch and is left untouched"); return
        }
        do { try FileStore.write(d, to: StoreFile.url) } catch {
            storeLog.error("Saving the store file failed: \(String(describing: error), privacy: .public)")
        }
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

// MARK: store file

enum StoreFile {
    static var url: URL { FileStore.defaultFile }
    /// Set when saved data exists but could not be read, so a save can't overwrite data we never saw.
    static var writesBlocked = false
}

// MARK: legacy Keychain item (0.1.4 and 0.1.5): read once and delete, for the one-time migration only
//
// Those versions kept the store in a login-keychain generic password (service = bundle id, account
// "store"). A self-signed app can't keep a stable Keychain ACL, so every launch asked for access.
// Nothing writes to the Keychain any more.

enum LegacyKeychain {
    static var service: String { Bundle.main.bundleIdentifier ?? "io.github.derkezorm.nexview.macos" }
    static let account = "store"

    enum ReadResult { case missing, data(Data), failure(OSStatus) }

    static func describe(_ st: OSStatus) -> String {
        "\(st) (\((SecCopyErrorMessageString(st, nil) as String?) ?? "unknown error"))"
    }

    static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Checks whether the item exists without reading its data (attributes only: no access prompt).
    static func exists() -> Bool {
        var q = query
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        return st != errSecItemNotFound
    }

    /// Reads the data. This is the one access that may show the Keychain prompt.
    static func read() -> ReadResult {
        var q = query
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

    /// Deletes the item. Failure is not fatal: store.json now exists, so the item is never read again.
    /// The "store.corrupt.*" copies older builds may have made are left alone: deleting items this app
    /// doesn't have access to could show more prompts, and they hold no passwords.
    static func delete() {
        let st = SecItemDelete(query as CFDictionary)
        if st == errSecSuccess || st == errSecItemNotFound {
            storeLog.notice("Legacy Keychain item deleted")
        } else {
            storeLog.error("Could not delete the legacy Keychain item: \(describe(st), privacy: .public); it won't be read again")
        }
    }
}

// MARK: loading at launch (once), including the one-time moves out of the Keychain and the old vault

enum StoreLoader {
    struct Message { var title: String; var text: String }

    /// The result of the single launch-time read; later calls return it instead of reading again.
    private static var cached: (store: ServerStore, alert: Message?)?

    static func load() -> (store: ServerStore, alert: Message?) {
        if let c = cached { return c }
        let r = loadOnce()
        cached = r
        return r
    }

    private static func loadOnce() -> (store: ServerStore, alert: Message?) {
        // (a) store.json exists: use it and never touch the Keychain.
        switch FileStore.read(StoreFile.url) {
        case .data(let d):
            do { return (try JSONDecoder().decode(ServerStore.self, from: d), nil) } catch {
                storeLog.error("store.json is undecodable: \(error.localizedDescription, privacy: .public)")
                return setAsideCorrupt()
            }
        case .failure(let e):
            storeLog.error("Reading store.json failed: \(e.localizedDescription, privacy: .public)")
            StoreFile.writesBlocked = true
            return (ServerStore(), Message(title: "Nexview couldn’t read its saved servers",
                text: "\(StoreFile.url.path) could not be read (\(e.localizedDescription)). Nothing was changed; quit and reopen Nexview to try again. Changes made in this session won’t be saved."))
        case .missing:
            break
        }
        // (b) the 0.1.4/0.1.5 Keychain item, (c) the 0.1.3 vault, (d) a fresh install.
        if LegacyKeychain.exists() { return migrateKeychain() }
        return migrateLegacyVault()
    }

    /// Keeps the undecodable file as store.corrupt-<timestamp>.json before starting over, never overwriting it.
    static func setAsideCorrupt() -> (store: ServerStore, alert: Message?) {
        do {
            let dest = try FileStore.setAsideCorrupt(StoreFile.url)
            storeLog.notice("Undecodable store.json kept as \(dest.lastPathComponent, privacy: .public)")
            return (ServerStore(), Message(title: "Your saved servers couldn’t be read",
                text: "Nexview’s saved data was damaged. A copy was kept as “\(dest.lastPathComponent)” in \(dest.deletingLastPathComponent().path). Please add your servers again in Settings."))
        } catch {
            storeLog.error("Could not set aside the undecodable store.json: \(String(describing: error), privacy: .public); leaving it untouched")
            StoreFile.writesBlocked = true
            return (ServerStore(), Message(title: "Nexview couldn’t read its saved servers",
                text: "The saved data is damaged and could not be set aside, so it was left untouched. Changes made in this session won’t be saved."))
        }
    }

    /// Writes data to store.json and checks that reading it back gives the same bytes and decodes.
    static func writeVerified(_ d: Data) -> Bool {
        do { try FileStore.write(d, to: StoreFile.url) } catch {
            storeLog.error("Migration: writing store.json failed: \(String(describing: error), privacy: .public)")
            return false
        }
        guard case .data(let back) = FileStore.read(StoreFile.url), back == d,
              (try? JSONDecoder().decode(ServerStore.self, from: back)) != nil else {
            storeLog.error("Migration: store.json read-back did not match")
            return false
        }
        return true
    }

    /// One last Keychain read (one prompt), then the file takes over and the item is deleted.
    static func migrateKeychain() -> (store: ServerStore, alert: Message?) {
        switch LegacyKeychain.read() {
        case .missing:
            return migrateLegacyVault()
        case .failure(let st):
            storeLog.error("Reading the legacy Keychain store failed: \(LegacyKeychain.describe(st), privacy: .public)")
            StoreFile.writesBlocked = true
            return (ServerStore(), Message(title: "Nexview couldn’t read its saved servers",
                text: "Nexview is moving your servers out of the macOS Keychain, but the Keychain refused access (\(LegacyKeychain.describe(st))). Nothing was changed; quit and reopen Nexview and choose Allow to finish the move. Changes made in this session won’t be saved."))
        case .data(let d):
            guard let store = try? JSONDecoder().decode(ServerStore.self, from: d) else {
                // Keep the damaged bytes as a corrupt copy on disk, then start over with an empty file.
                storeLog.error("Legacy Keychain store is undecodable")
                let tmp = StoreFile.url
                do {
                    try FileStore.write(d, to: tmp)
                    let dest = try FileStore.setAsideCorrupt(tmp)
                    LegacyKeychain.delete()
                    return (ServerStore(), Message(title: "Your saved servers couldn’t be read",
                        text: "Nexview’s saved data in the Keychain was damaged. A copy was kept as “\(dest.lastPathComponent)” in \(dest.deletingLastPathComponent().path). Please add your servers again in Settings."))
                } catch {
                    storeLog.error("Could not keep a copy of the undecodable Keychain store: \(String(describing: error), privacy: .public); leaving it untouched")
                    StoreFile.writesBlocked = true
                    return (ServerStore(), Message(title: "Nexview couldn’t read its saved servers",
                        text: "The saved data in the Keychain is damaged and could not be backed up, so it was left untouched. Changes made in this session won’t be saved."))
                }
            }
            guard writeVerified(d) else {
                // Keychain item kept, so the next launch tries again; block saves this session so a later
                // save can't leave a file that differs from the item.
                StoreFile.writesBlocked = true
                return (store, nil)
            }
            LegacyKeychain.delete()
            storeLog.notice("Migrated \(store.servers.count) server(s) from the Keychain to store.json")
            return (store, nil)
        }
    }

    static func migrateLegacyVault() -> (store: ServerStore, alert: Message?) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: LegacyVault.vaultFile.path) else { return (ServerStore(), nil) }   // fresh install
        guard let plain = LegacyVault.read() else {
            storeLog.error("Old vault could not be decrypted; keeping it as .bak")
            LegacyVault.setAside()
            return (ServerStore(), Message(title: "Please add your servers again",
                text: "The old saved data on this Mac could not be read. It was kept as a backup (vault.bin.bak). Add your servers again in Settings; you sign in through the page as before."))
        }
        let store: ServerStore
        do { store = try JSONDecoder().decode(ServerStore.self, from: plain) } catch {
            storeLog.error("Old vault decrypted but is undecodable: \(error.localizedDescription, privacy: .public); keeping it as .bak")
            LegacyVault.setAside()
            return (ServerStore(), Message(title: "Please add your servers again",
                text: "The old saved data on this Mac could not be read. It was kept as a backup (vault.bin.bak). Add your servers again in Settings."))
        }
        // Re-encoding drops the saved sign-ins (passwords): ServerStore has no field for them.
        guard let d = try? JSONEncoder().encode(store) else { return (store, nil) }
        guard writeVerified(d) else {
            storeLog.error("Migration: old vault kept")
            return (store, nil)
        }
        LegacyVault.deleteFiles()
        storeLog.notice("Migrated \(store.servers.count) server(s) from the old vault to store.json; saved passwords deleted")
        return (store, nil)
    }
}

// MARK: legacy Secure Enclave vault (read-only, for the one-time migration)
//
// Up to 0.1.3 the store, including saved passwords, was encrypted with a Secure Enclave key whose
// opaque handle lived in enclave.key next to vault.bin. Only reading it is kept here.

enum LegacyVault {
    static var dir: URL { FileStore.defaultDir }
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
