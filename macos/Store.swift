// Server list and read-only keys in the macOS Keychain, loading at launch and the legacy vault migration.
import Foundation
import SwiftUI   // MutableCollection.move(fromOffsets:toOffset:)
import CryptoKit
import Security
import os

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
