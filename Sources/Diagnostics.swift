import Foundation

struct KeepAwakeConfiguration: Codable, Equatable {
    var wantAwake: Bool
    var allowOnBattery: Bool
    var minBatteryPercent: Int
    var virtualDisplay: Bool
    var startAtLogin: Bool

    var doubleClickToToggle: Bool? = nil
    var stopOnSeriousThermal: Bool? = nil

    static var current: KeepAwakeConfiguration {
        KeepAwakeConfiguration(wantAwake: Prefs.wantAwake, allowOnBattery: Prefs.allowOnBattery,
                               minBatteryPercent: Prefs.minBatteryPercent, virtualDisplay: Prefs.virtualDisplay,
                               startAtLogin: LoginItem.isEnabled, doubleClickToToggle: Prefs.doubleClickToToggle,
                               stopOnSeriousThermal: Prefs.stopOnSeriousThermal)
    }
}

/// Values observed at an event, separate from the desired setting and display-object ownership.
struct DiagnosticContext: Codable, Equatable {
    var lidClosed: Bool?
    var power: PowerState
    var thermal: String
    var sensorsKnown: Bool
    var configuration: KeepAwakeConfiguration
    var guardReason: String?
    var cachedSleepDisabled: Bool
    var sleepObservation: Pmset.SleepObservation?
    var assertionHeld: Bool
    var virtualDisplayOwned: Bool
    var displays: DisplayState
    var screensAsleep: Bool?
    var sessionActive: Bool?
    var screenLocked: Bool?
    var virtualDisplaySuspension: String? = nil

    var fields: [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var values = (try? JSONSerialization.jsonObject(with: encoder.encode(self))) as? [String: Any] ?? [:]
        // Preserve unknown observations as null, rather than silently turning them into false.
        for key in ["lidClosed", "guardReason", "screensAsleep", "sessionActive", "screenLocked", "sleepObservation", "virtualDisplaySuspension"] {
            if values[key] == nil { values[key] = NSNull() }
        }
        return values
    }

    /// Ignore sampling timestamps when detecting transitions; an unchanged refresh stays quiet.
    func changes(from previous: DiagnosticContext) -> [String] {
        var events: [String] = []
        if lidClosed != previous.lidClosed { events.append("lid_transition") }
        if power != previous.power || sensorsKnown != previous.sensorsKnown { events.append("power_transition") }
        if thermal != previous.thermal { events.append("thermal_transition") }
        if configuration != previous.configuration { events.append("configuration_transition") }
        if guardReason != previous.guardReason || cachedSleepDisabled != previous.cachedSleepDisabled
            || sleepObservation?.value != previous.sleepObservation?.value
            || sleepObservation?.error != previous.sleepObservation?.error || assertionHeld != previous.assertionHeld {
            events.append("protection_transition")
        }
        if displays != previous.displays || virtualDisplayOwned != previous.virtualDisplayOwned
            || virtualDisplaySuspension != previous.virtualDisplaySuspension {
            events.append("display_transition")
        }
        return events
    }
}

struct TickGap: Equatable {
    var wallSeconds: TimeInterval
    var uptimeSeconds: TimeInterval
    var wallMinusUptimeSeconds: TimeInterval { wallSeconds - uptimeSeconds }
    var shouldLog: Bool { wallSeconds > 15 || wallSeconds < 0 || uptimeSeconds > 15 || abs(wallMinusUptimeSeconds) > 5 }
    var fields: [String: Any] {
        ["wallGapSeconds": wallSeconds, "monotonicGapSeconds": uptimeSeconds,
         "wallMinusMonotonicSeconds": wallMinusUptimeSeconds,
         "interpretation": "A scheduling gap alone is not proof of system sleep; correlate workspace notifications and pmset evidence."]
    }
}
