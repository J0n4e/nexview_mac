// Run: swiftc -parse-as-library macos/Updater.swift macos/tests/updater-check-test.swift -o /tmp/ct && /tmp/ct
import Foundation

func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: \(what)"); exit(1) } }

@main struct UpdaterCheckTest {
    static func main() {
        typealias S = Updater.CheckStatus
        check(Updater.classifyCheck(statusCode: 200, rateLimitRemaining: "59", transportFailed: false) == S.ok, "200 is ok")
        check(Updater.classifyCheck(statusCode: nil, rateLimitRemaining: nil, transportFailed: true) == S.offline, "no response is offline")
        check(Updater.classifyCheck(statusCode: 403, rateLimitRemaining: "0", transportFailed: false) == S.rateLimited, "403 + remaining 0 is rate limited")
        check(Updater.classifyCheck(statusCode: 429, rateLimitRemaining: nil, transportFailed: false) == S.rateLimited, "429 is rate limited")
        check(Updater.classifyCheck(statusCode: 403, rateLimitRemaining: "12", transportFailed: false) == S.serverError(403), "403 with quota left is not a rate limit")
        check(Updater.classifyCheck(statusCode: 500, rateLimitRemaining: nil, transportFailed: false) == S.serverError(500), "500 is a server error")
        check(Updater.checkFailureText(.rateLimited) != Updater.checkFailureText(.offline), "distinct messages")

        let s = Updater.swapScript
        check(s.contains("/usr/bin/codesign --verify --deep --strict \"$new\""), "script re-verifies the new bundle")
        check(s.contains("CFBundleIdentifier") && s.contains("CFBundleShortVersionString"), "script checks id and version")
        check(s.contains("262144"), "script rotates the log at 256 KB")
        check(!s.contains("\\("), "no Swift interpolation in the script")
        let args = Updater.swapArguments(app: "/a b/N.app", target: "/Apps/N.app", dir: "/tmp/x", version: "1.2.3", log: "/l/update.log", pid: 42)
        check(args.count == 10 && args[0] == "-c" && args[1] == s && args[2] == "nexview-update", "zsh -c layout")
        check(Array(args[3...]) == ["/a b/N.app", "/Apps/N.app", "/tmp/x", Updater.bundleID, "1.2.3", "/l/update.log", "42"], "positional args")
        check(Updater.updateLogURL.path.hasSuffix("Library/Logs/Nexview/update.log"), "log path")
        print("ok")
    }
}
