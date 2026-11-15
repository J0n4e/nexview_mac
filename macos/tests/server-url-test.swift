// Run: swiftc -parse-as-library macos/Updater.swift macos/ServerURL.swift macos/Backoff.swift macos/tests/server-url-test.swift -o /tmp/st && /tmp/st
import Foundation

func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: \(what)"); exit(1) } }
func eq(_ a: String?, _ b: String?, _ what: String) { check(a == b, "\(what): got \(a ?? "nil"), want \(b ?? "nil")") }

@main struct ServerURLTest {
    static func main() {
        eq(ServerURL.parse("nexview.example.com")?.absoluteString, "https://nexview.example.com/", "default https + slash")
        eq(ServerURL.parse("  192.168.1.10:8000 ")?.absoluteString, "https://192.168.1.10:8000/", "trim, keep port")
        eq(ServerURL.parse("HTTP://NAS.Local:80")?.absoluteString, "http://nas.local/", "lowercase, strip :80")
        eq(ServerURL.parse("https://Example.com:443/nexview")?.absoluteString, "https://example.com/nexview/", "strip :443, keep path")
        eq(ServerURL.parse("http://example.com:443")?.absoluteString, "http://example.com:443/", "443 is not default for http")
        eq(ServerURL.parse("http://[::1]:80/")?.absoluteString, "http://[::1]/", "ipv6 default port")
        eq(ServerURL.parse("http://[::1]:8000")?.absoluteString, "http://[::1]:8000/", "ipv6 port")
        check(ServerURL.parse("") == nil, "empty is invalid")
        check(ServerURL.parse("https://") == nil, "no host is invalid")

        eq(ServerURL.key("https://Example.com:443/"), "https://example.com", "key strips slash")
        check(ServerURL.key("example.com") == ServerURL.key("HTTPS://EXAMPLE.COM:443/"), "same key")

        let list = ["https://a.example/", "http://nas:8000/", "https://b.example/sub/"]
        eq(ServerURL.duplicate(of: "A.EXAMPLE", in: list).map(String.init), "0", "duplicate found")
        check(ServerURL.duplicate(of: "a.example", in: list, except: 0) == nil, "editing itself is not a duplicate")
        check(ServerURL.duplicate(of: "http://nas:8001", in: list) == nil, "other port is not a duplicate")
        check(ServerURL.duplicate(of: "https://b.example/sub", in: list) == 2, "path without slash is a duplicate")
        check(ServerURL.duplicate(of: "https://b.example/", in: list) == nil, "other path is not a duplicate")

        check(ServerURL.sameInstance("http://nas:8000/", "https://NAS/"), "scheme/port change keeps instance")
        check(ServerURL.sameInstance("https://a.example/x/", "https://a.example/x"), "same path")
        check(!ServerURL.sameInstance("https://a.example/", "https://b.example/"), "other host")
        check(!ServerURL.sameInstance("https://a.example/x/", "https://a.example/y/"), "other path")
        print("ok")
    }
}
