import Foundation

enum InactivitySleepPolicy {
    static func shouldRestart(minutes: Int, pending: Bool, idle: TimeInterval) -> Bool {
        minutes > 0 && pending && idle.isFinite && idle >= 0 && idle < Double(minutes * 60)
    }
    static func expired(minutes: Int, awake: Bool, idle: TimeInterval, armedFor: TimeInterval) -> Bool {
        minutes > 0 && awake && idle.isFinite && idle >= 0 && armedFor >= 0 && min(idle, armedFor) >= Double(minutes * 60)
    }
    static func shouldRetry(minutes: Int, pending: Bool, idle: TimeInterval, sleepDisabled: Bool?, now: TimeInterval, lastAttempt: TimeInterval?) -> Bool {
        guard minutes > 0, pending, idle.isFinite, idle >= Double(minutes * 60), sleepDisabled == false else { return false }
        return lastAttempt.map { now - $0 >= 30 } ?? true
    }
}

struct GuardInput: Equatable {
    var lidClosed: Bool
    var onAC: Bool
    var batteryPercent: Int?
    var thermal: String
    var allowOnBattery: Bool
    var minBatteryPercent: Int
    var sensorsKnown = true
}

enum GuardDecision: Equatable {
    case allow
    case block(String)

    var reason: String? {
        if case .block(let reason) = self { return reason }
        return nil
    }
}

/// SleepDisabled also switches off macOS's own low-battery sleep, so Caffeine has to provide
/// the safety net itself. Any block clears SleepDisabled; with the lid closed it also sleeps the Mac.
enum Guards {
    static func evaluate(_ input: GuardInput) -> GuardDecision {
        if !input.sensorsKnown { return .block("power or lid sensor unavailable") }
        if input.thermal == "unknown" { return .block("temperature unavailable") }
        if input.thermal == "critical" { return .block("Mac is critically hot") }
        if !input.onAC {
            guard input.batteryPercent != nil else { return .block("battery level unavailable") }
            if let percent = input.batteryPercent, percent <= input.minBatteryPercent {
                return .block("battery at \(percent)%")
            }
            // The "closed in a bag" case: unplugged with the lid shut.
            if input.lidClosed && !input.allowOnBattery { return .block("lid closed on battery") }
        }
        return .allow
    }
}

/// Sustained serious pressure is optional; critical always stops keep-awake immediately.
struct ThermalStopPolicy {
    private var seriousSince: TimeInterval?
    mutating func evaluate(thermal: String, enabled: Bool, now: TimeInterval) -> String? {
        if thermal == "critical" { seriousSince = nil; return "Critical thermal pressure" }
        guard thermal == "serious", enabled else { seriousSince = nil; return nil }
        if seriousSince == nil { seriousSince = now }
        return now - (seriousSince ?? now) >= 60 ? "Sustained serious thermal pressure" : nil
    }
}

/// Throttles explicit sleep requests while waiting for an actual system-sleep event.
struct SleepRetryPolicy {
    private var lastAttempt: TimeInterval?
    mutating func shouldRequest(pending: Bool, lidClosed: Bool?, normalSleepConfirmed: Bool, now: TimeInterval) -> Bool {
        guard pending, lidClosed == true, normalSleepConfirmed else { return false }
        if let lastAttempt, now - lastAttempt < 30 { return false }
        lastAttempt = now
        return true
    }
    mutating func reset() { lastAttempt = nil }
}

/// Watches lid-closed stretches. The app beats every few seconds; because timers stop while the
/// Mac sleeps, a long gap between beats means the Mac was asleep.
final class LidTracker {
    struct Session: Equatable {
        var closedAt: Date
        var openedAt: Date
        var maxGap: TimeInterval
        var activeThroughout: Bool
    }

    enum Event: Equatable {
        case none
        case closed
        case opened(Session)
    }

    private(set) var closedAt: Date?
    private var lastBeat: Date?
    private var maxGap: TimeInterval = 0
    private var activeThroughout = true

    func beat(now: Date, lidClosed: Bool, active: Bool) -> Event {
        defer { lastBeat = now }
        let gap = lastBeat.map { now.timeIntervalSince($0) } ?? 0
        if lidClosed {
            guard closedAt != nil else {
                closedAt = now
                maxGap = 0
                activeThroughout = active
                return .closed
            }
            maxGap = max(maxGap, gap)
            if !active { activeThroughout = false }
            return .none
        }
        guard let start = closedAt else { return .none }
        closedAt = nil
        return .opened(Session(closedAt: start, openedAt: now, maxGap: max(maxGap, gap), activeThroughout: activeThroughout))
    }
}

struct LidSessionResult: Codable, Equatable {
    var closedAt: Date
    var openedAt: Date
    var maxGapSeconds: Int
    var sleepEvents: Int
    var activeThroughout: Bool
    /// Why Caffeine wasn't keeping the Mac awake when the lid closed (a guard, or keep-awake off).
    var pausedReason: String? = nil
    var sleepLogAvailable: Bool? = nil

    var minutes: Int { Int(openedAt.timeIntervalSince(closedAt) / 60) }
    var stayedAwake: Bool { sleepLogAvailable != false && sleepEvents == 0 && maxGapSeconds < 60 }
    private var pause: String? { pausedReason ?? (activeThroughout ? nil : "Caffeine was paused or off") }
    /// Slept although Caffeine was on and no guard had paused it: the case that means it didn't work.
    var failed: Bool { !stayedAwake && pause == nil && (sleepEvents > 0 || maxGapSeconds >= 60) }

    var summary: String {
        let time = DateFormatter.localizedString(from: closedAt, dateStyle: .none, timeStyle: .short)
        let prefix = "Lid closed \(minutes) min at \(time)"
        if sleepLogAvailable == false { return "\(prefix): system sleep log unavailable (\(maxGapSeconds) s timer gap)" }
        if stayedAwake { return "\(prefix): stayed awake" }
        if let pause { return "\(prefix): slept as expected (\(pause))" }
        if sleepEvents > 0 { return "\(prefix): slept \(sleepEvents)× while Caffeine was on" }
        return "\(prefix): \(maxGapSeconds / 60) min gap while Caffeine was on (slept?)"
    }
}
