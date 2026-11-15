// Foundation-only file helpers for the store: a user-only directory (0700) and atomic 0600 writes.
// No AppKit and no os.Logger here, so macos/tests/filestore-test.swift can compile it on its own.
import Foundation

enum FileStore {
    /// ~/Library/Application Support/Nexview for Mac
    static var defaultDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nexview for Mac", isDirectory: true)
    }
    static var defaultFile: URL { defaultDir.appendingPathComponent("store.json") }

    enum ReadResult { case missing, data(Data), failure(Error) }

    struct POSIXFailure: Error, CustomStringConvertible {
        var op: String; var code: Int32
        var description: String { "\(op): \(String(cString: strerror(code))) (\(code))" }
    }

    /// POSIX permission bits (e.g. 0o600), or nil if the path doesn't exist.
    static func permissions(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    }

    /// Creates the directory with 0700, or tightens an existing one that is looser.
    static func ensureDir(_ dir: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        if let p = permissions(dir), p & 0o077 != 0 {
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
    }

    /// Writes atomically: a 0600 temp file in the same directory, fsync, then rename over the target.
    static func write(_ d: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try ensureDir(dir)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXFailure(op: "open", code: errno) }
        var ok = false
        defer { if !ok { unlink(tmp.path) } }
        fchmod(fd, 0o600)   // umask can't loosen it, but make sure
        let written: Int = d.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = Foundation.write(fd, buf.baseAddress! + off, buf.count - off)
                if n < 0 { if errno == EINTR { continue }; return -1 }
                off += n
            }
            return off
        }
        if written != d.count { let e = errno; close(fd); throw POSIXFailure(op: "write", code: e) }
        if fsync(fd) != 0 { let e = errno; close(fd); throw POSIXFailure(op: "fsync", code: e) }
        close(fd)
        guard rename(tmp.path, url.path) == 0 else { throw POSIXFailure(op: "rename", code: errno) }
        ok = true
    }

    /// Reads the file, tightening its permissions to 0600 first if they are looser.
    static func read(_ url: URL) -> ReadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        if let p = permissions(url), p & 0o077 != 0 {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        do { return .data(try Data(contentsOf: url)) } catch { return .failure(error) }
    }

    /// Renames an undecodable file to store.corrupt-<timestamp>.json next to it (never deletes it).
    static func setAsideCorrupt(_ url: URL, now: Date = Date()) throws -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let base = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        var dest = dir.appendingPathComponent("\(base).corrupt-\(f.string(from: now)).json")
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            n += 1; dest = dir.appendingPathComponent("\(base).corrupt-\(f.string(from: now))-\(n).json")
        }
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    }
}
