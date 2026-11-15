// Run: swiftc -parse-as-library macos/Updater.swift macos/ServerURL.swift macos/Backoff.swift macos/tests/backoff-test.swift -o /tmp/bt && /tmp/bt
import Foundation

func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: \(what)"); exit(1) } }

@main struct BackoffTest {
    static func main() {
        check(Backoff.interval(failures: 0) == 60, "no failures: 60 s")
        check(Backoff.interval(failures: 1) == 60, "first failure: still 60 s")
        check(Backoff.interval(failures: 2) == 120, "second failure: 120 s")
        check(Backoff.interval(failures: 3) == 240, "third failure: 240 s")
        check(Backoff.interval(failures: 4) == 480, "fourth failure: 480 s")
        check(Backoff.interval(failures: 5) == 900, "capped at 15 min")
        check(Backoff.interval(failures: 1000) == 900, "no overflow, still capped")
        check(Backoff.interval(failures: -3) == 60, "negative is base")

        check(Backoff.isFailure(status: 0), "network error")
        check(Backoff.isFailure(status: 500) && Backoff.isFailure(status: 503) && Backoff.isFailure(status: 599), "5xx")
        check(!Backoff.isFailure(status: 200), "200 ok")
        check(!Backoff.isFailure(status: 401) && !Backoff.isFailure(status: 404), "4xx is not a back-off failure")

        let now = Date(timeIntervalSince1970: 1_000_000)
        check(Backoff.isDue(next: nil, now: now), "never failed: due")
        check(Backoff.isDue(next: now, now: now), "due now")
        check(Backoff.isDue(next: now.addingTimeInterval(10), now: now), "within slack")
        check(!Backoff.isDue(next: now.addingTimeInterval(100), now: now), "not yet due")
        print("ok")
    }
}
