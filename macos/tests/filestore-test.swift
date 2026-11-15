// Run: swiftc -parse-as-library macos/Updater.swift macos/ServerURL.swift macos/Backoff.swift macos/FileStore.swift macos/tests/filestore-test.swift -o /tmp/ft && /tmp/ft
import Foundation

func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: \(what)"); exit(1) } }

@main struct FileStoreTest {
    static func main() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("filestore-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let dir = root.appendingPathComponent("Nexview for Mac", isDirectory: true)
        let file = dir.appendingPathComponent("store.json")

        check(FileStore.defaultFile.path.hasSuffix("Library/Application Support/Nexview for Mac/store.json"), "default path")
        if case .missing = FileStore.read(file) {} else { check(false, "missing before write") }

        let a = Data(#"{"servers":[{"name":"A","url":"https://a.example"}],"selected":0}"#.utf8)
        do { try FileStore.write(a, to: file) } catch { check(false, "write: \(error)") }
        check(FileStore.permissions(dir) == 0o700, "dir is 0700")
        check(FileStore.permissions(file) == 0o600, "file is 0600")
        if case .data(let d) = FileStore.read(file) { check(d == a, "round-trip") } else { check(false, "read") }

        // Overwrite is atomic and leaves no temp files.
        let b = Data(#"{"servers":[],"selected":0}"#.utf8)
        do { try FileStore.write(b, to: file) } catch { check(false, "rewrite: \(error)") }
        if case .data(let d) = FileStore.read(file) { check(d == b, "rewrite round-trip") } else { check(false, "reread") }
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        check(names == ["store.json"], "no temp files left: \(names)")
        check(FileStore.permissions(file) == 0o600, "still 0600 after rewrite")

        // Empty data works.
        do { try FileStore.write(Data(), to: file) } catch { check(false, "empty write: \(error)") }
        if case .data(let d) = FileStore.read(file) { check(d.isEmpty, "empty round-trip") } else { check(false, "empty read") }

        // Loose permissions are tightened on read; a loose directory is tightened on write.
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        _ = FileStore.read(file)
        check(FileStore.permissions(file) == 0o600, "read fixes 0644 to 0600")
        do { try FileStore.write(b, to: file) } catch { check(false, "write: \(error)") }
        check(FileStore.permissions(dir) == 0o700, "write fixes dir to 0700")

        // Corrupt file: set aside under a timestamped name, original content kept, never overwritten.
        let junk = Data("not json".utf8)
        do { try FileStore.write(junk, to: file) } catch { check(false, "write junk") }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        guard let c1 = try? FileStore.setAsideCorrupt(file, now: now) else { check(false, "set aside"); return }
        check(c1.lastPathComponent == "store.corrupt-20231114T221320Z.json", "corrupt name: \(c1.lastPathComponent)")
        check(!fm.fileExists(atPath: file.path), "original moved away")
        check((try? Data(contentsOf: c1)) == junk, "corrupt copy keeps the data")
        do { try FileStore.write(junk, to: file) } catch { check(false, "write junk 2") }
        guard let c2 = try? FileStore.setAsideCorrupt(file, now: now) else { check(false, "set aside 2"); return }
        check(c2 != c1 && fm.fileExists(atPath: c1.path), "same timestamp doesn't overwrite the first copy")
        print("ok")
    }
}
