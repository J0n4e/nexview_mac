// Polling back-off for servers that keep failing. Foundation only, so macos/tests/backoff-test.swift can compile it.
import Foundation

enum Backoff {
    /// Normal polling interval and the longest wait between checks of a failing server.
    static let base: TimeInterval = 60
    static let cap: TimeInterval = 15 * 60

    /// Seconds until the next check after `failures` consecutive failures:
    /// 0 or 1 -> 60 s, 2 -> 120 s, 3 -> 240 s, ... capped at 15 min.
    static func interval(failures: Int, base: TimeInterval = base, cap: TimeInterval = cap) -> TimeInterval {
        guard failures > 1 else { return base }
        let exp = min(failures - 1, 30)                 // no overflow for long outages
        return min(base * pow(2, Double(exp)), cap)
    }

    /// A poll result that counts as a failure: no HTTP response (network error, timeout) or a 5xx.
    static func isFailure(status: Int) -> Bool { status == 0 || (500...599).contains(status) }

    /// Whether a server with this next-check time is due. `slack` absorbs timer tolerance, so a server
    /// due a few seconds after the minute tick is not pushed to the next one.
    static func isDue(next: Date?, now: Date, slack: TimeInterval = 15) -> Bool {
        guard let next else { return true }
        return next.timeIntervalSince(now) <= slack
    }
}
