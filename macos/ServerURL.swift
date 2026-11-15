// Server addresses: normalising, duplicate detection and the "same server?" rule.
// Foundation only, so macos/tests/server-url-test.swift can compile it without AppKit.
import Foundation

enum ServerURL {
    /// Turns what the user typed ("192.168.1.10:8000", "HTTPS://Nexview.Example.com:443") into the
    /// stored form: scheme and host lowercased, default port (80 for http, 443 for https) removed,
    /// and always ending in "/" (relative API paths are resolved against it). nil if not usable.
    static func parse(_ raw: String) -> URL? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if !t.contains("://") { t = "https://" + t }
        guard let p = parts(t) else { return nil }
        var path = p.rest
        if path.isEmpty || path.first == "?" || path.first == "#" { path = "/" + path }
        if !path.contains("?") && !path.contains("#") && !path.hasSuffix("/") { path += "/" }
        guard let u = URL(string: "\(p.scheme)://\(p.authority)\(path)"), u.host != nil, !p.host.isEmpty else { return nil }
        return u
    }

    /// Comparison key: the normalised form without the trailing slash. Two addresses with the same
    /// key are the same server entry. Unparseable input falls back to a trimmed, lowercased string.
    static func key(_ s: String) -> String {
        var k = parse(s)?.absoluteString ?? s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while k.hasSuffix("/") { k.removeLast() }
        return k
    }

    /// Index of another entry in `urls` (other than `except`) that already uses this address.
    static func duplicate(of url: String, in urls: [String], except: Int? = nil) -> Int? {
        let k = key(url)
        return urls.indices.first { $0 != except && key(urls[$0]) == k }
    }

    /// Rule for an edited address: is it still the same Nexview instance?
    /// Same host (case-insensitive) and same base path => yes, even if the scheme or port changed
    /// (e.g. moving from http://nas:8000 to https://nas behind a proxy). Then the read-only key,
    /// queued mark-reads and notification state move to the new address.
    /// A different host or base path => a different server: the old key belongs to the old server,
    /// so it is dropped (and deleted there if possible), along with the old per-server state.
    static func sameInstance(_ a: String, _ b: String) -> Bool {
        guard let x = parse(a).flatMap({ parts($0.absoluteString) }),
              let y = parse(b).flatMap({ parts($0.absoluteString) }) else { return key(a) == key(b) }
        func base(_ r: String) -> String {
            var s = String(r.prefix { $0 != "?" && $0 != "#" })
            while s.hasSuffix("/") { s.removeLast() }
            return s
        }
        return x.host == y.host && base(x.rest) == base(y.rest)
    }

    /// Splits "scheme://authority/rest" and normalises scheme, host and port.
    static func parts(_ s: String) -> (scheme: String, authority: String, host: String, rest: String)? {
        guard let r = s.range(of: "://") else { return nil }
        let scheme = s[..<r.lowerBound].lowercased()
        guard !scheme.isEmpty else { return nil }
        let after = s[r.upperBound...]
        let end = after.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? after.endIndex
        var auth = String(after[..<end]); let rest = String(after[end...])
        var user = ""
        if let at = auth.lastIndex(of: "@") { user = String(auth[...at]); auth = String(auth[auth.index(after: at)...]) }
        auth = auth.lowercased()
        var host = auth, port = ""
        if auth.hasPrefix("[") {
            guard let close = auth.firstIndex(of: "]") else { return nil }
            host = String(auth[...close]); port = String(auth[auth.index(after: close)...])
        } else if let c = auth.lastIndex(of: ":") {
            host = String(auth[..<c]); port = String(auth[c...])
        }
        if port == ":" || (scheme == "http" && port == ":80") || (scheme == "https" && port == ":443") { port = "" }
        return (scheme, user + host + port, host, rest)
    }
}
