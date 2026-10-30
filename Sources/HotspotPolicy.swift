import Foundation

struct HotspotProfile {
    let name: String
    let lastConnected: Date
    let personal: Bool

    static func mostRecent(in profiles: [HotspotProfile]) -> HotspotProfile? {
        profiles.filter { $0.personal && !$0.name.isEmpty }.max { $0.lastConnected < $1.lastConnected }
    }
}

/// Require repeated failures and bound retries to avoid network thrashing.
struct HotspotRetryPolicy {
    private var failures = 0
    private var lastAttempt: TimeInterval?
    mutating func observe(online: Bool, now: TimeInterval) -> Bool {
        if online { failures = 0; return false }
        failures += 1
        guard failures >= 2 else { return false }
        if let lastAttempt, now - lastAttempt < 300 { return false }
        failures = 0
        lastAttempt = now
        return true
    }
    mutating func reset() { failures = 0; lastAttempt = nil }
}
