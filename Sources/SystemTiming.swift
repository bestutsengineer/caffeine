import Foundation

/// Configured idle policies, not a prediction: lid close, manual sleep and assertions differ.
struct SystemTiming: Codable, Equatable {
    var sampledAt: Date
    var batterySleepMinutes: Int?
    var acSleepMinutes: Int?
    var batteryDisplayMinutes: Int?
    var acDisplayMinutes: Int?
    var screenSaverSeconds: Int?
    /// -1: not required, 0: immediate, nil: unavailable.
    var passwordDelaySeconds: Int?

    static func parse(_ custom: String, password: String, saver: String, at: Date = Date()) -> SystemTiming {
        var result = SystemTiming(sampledAt: at)
        var ac: Bool?
        for line in custom.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text == "Battery Power:" { ac = false; continue }
            if text == "AC Power:" { ac = true; continue }
            let fields = text.split(whereSeparator: \.isWhitespace)
            guard let ac, fields.count == 2, let value = Int(fields[1]), value >= 0 else { continue }
            if fields[0] == "sleep" {
                if ac { result.acSleepMinutes = value } else { result.batterySleepMinutes = value }
            }
            if fields[0] == "displaysleep" {
                if ac { result.acDisplayMinutes = value } else { result.batteryDisplayMinutes = value }
            }
        }
        result.screenSaverSeconds = Int(saver.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0 >= 0 ? $0 : nil }
        let lock = password.lowercased()
        if lock.contains("screenlock") {
            if lock.contains("immediate") { result.passwordDelaySeconds = 0 }
            else if lock.range(of: #"screenlock (?:is |delay is )?(?:off|disabled)\b"#, options: .regularExpression) != nil {
                result.passwordDelaySeconds = -1
            } else if let range = lock.range(of: #"screenlock delay is [0-9]+ (?:seconds?|minutes?|hours?)"#, options: .regularExpression) {
                let parts = lock[range].split(separator: " ")
                if let value = Int(parts[3]) {
                    result.passwordDelaySeconds = value * (parts[4].hasPrefix("hour") ? 3600 : parts[4].hasPrefix("minute") ? 60 : 1)
                }
            }
        }
        return result
    }
    static func duration(_ seconds: Int?) -> String {
        guard let seconds else { return "Unavailable" }
        if seconds == 0 { return "Never (configured)" }
        if seconds < 60 { return "\(seconds) sec" }
        if seconds % 60 == 0 { return "\(seconds / 60) min" }
        return "\(seconds / 60) min \(seconds % 60) sec"
    }
    func rows(onAC: Bool) -> [String] {
        let sleep = onAC ? acSleepMinutes : batterySleepMinutes
        let display = onAC ? acDisplayMinutes : batteryDisplayMinutes
        let password: String
        switch passwordDelaySeconds {
        case .some(-1): password = "Not required (configured)"
        case .some(0): password = "Immediately after screen saver/display off"
        case .some(let seconds): password = "\(Self.duration(seconds)) after screen saver/display off"
        case .none: password = "Unavailable — check Lock Screen Settings"
        }
        return ["Current power: \(onAC ? "power adapter" : "battery")",
                "Idle sleep when Caffeine is off: \(Self.duration(sleep.map { $0 * 60 }))",
                "Display off after idle: \(Self.duration(display.map { $0 * 60 }))",
                "Screen saver after idle: \(Self.duration(screenSaverSeconds))",
                "Require password: \(password)",
                "Configured delays, not a countdown"]
    }
}

enum SystemTimingReader {
    private static let lock = NSLock()
    private static var cached: SystemTiming?
    static func read() -> SystemTiming {
        lock.lock(); defer { lock.unlock() }
        if let cached, Date().timeIntervalSince(cached.sampledAt) < 30 { return cached }
        let power = Shell.run("/usr/bin/pmset", ["-g", "custom"], timeout: 3)
        let password = Shell.run("/usr/sbin/sysadminctl", ["-screenLock", "status"], timeout: 3)
        let saver = Shell.run("/usr/bin/defaults", ["-currentHost", "read", "com.apple.screensaver", "idleTime"], timeout: 3)
        let value = SystemTiming.parse(power.ok ? power.stdout : "", password: password.ok ? password.stdout + password.stderr : "",
                                       saver: saver.ok ? saver.stdout : "")
        cached = value
        return value
    }
}

enum IconClick {
    enum Action: Equatable { case showMenu, deferMenu, toggle, ignore }
    static func action(clickCount: Int, rightButton: Bool, enabled: Bool) -> Action {
        if rightButton || !enabled { return .showMenu }
        if clickCount == 1 { return .deferMenu }
        if clickCount == 2 { return .toggle }
        return .ignore
    }
}
