// Run: swiftc macos/Updater.swift macos/tests/version-test.swift -o /tmp/vt && /tmp/vt
import Foundation

func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: \(what)"); exit(1) } }

@main struct VersionTest {
    static func main() {
        check(Updater.isNewer("0.1.10", than: "0.1.9"), "0.1.10 > 0.1.9")
        check(Updater.isNewer("v0.2", than: "0.1.9"), "v0.2 > 0.1.9")
        check(!Updater.isNewer("0.1.1", than: "0.1.1"), "equal is not newer")
        check(!Updater.isNewer("0.1.0", than: "0.1.1"), "older is not newer")
        check(!Updater.isNewer("junk", than: "0.1.1"), "junk is not newer")
        print("ok")
    }
}
