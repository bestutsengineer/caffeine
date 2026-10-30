import Foundation

struct RestartSchedule {
    let enabled: Bool
    let hour: Int
    let minute: Int
    static let path = "/Library/Preferences/local.caffeine.restart.plist"

    static func read() -> RestartSchedule {
        let fallback = RestartSchedule(enabled: false, hour: 5, minute: 0)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.ownerAccountID] as? NSNumber)?.intValue == 0,
              let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue, mode & 0o022 == 0,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let p = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let enabled = p["Enabled"] as? Bool, let hour = p["Hour"] as? Int, let minute = p["Minute"] as? Int,
              (0...23).contains(hour), (0...59).contains(minute) else { return fallback }
        return RestartSchedule(enabled: enabled, hour: hour, minute: minute)
    }

    static func parseTime(_ value: String) -> (Int, Int)? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let hour = Int(parts[0]), let minute = Int(parts[1]), (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }

    var label: String { enabled ? String(format: "%02d:%02d", hour, minute) : "Off" }

    /// Called only from the explicit opt-in UI; macOS requests administrator authentication.
    static func configure(enabled: Bool, hour: Int, minute: Int) -> String? {
        guard let resource = Bundle.main.resourceURL?.appendingPathComponent("prelogin-guard/configure-restart").path else {
            return "Scheduled restart setup is unavailable."
        }
        let prefs = NSHomeDirectory() + "/Library/Preferences/local.caffeine.plist"
        func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = ["/bin/sh", resource, enabled ? "on" : "off", String(hour), String(minute), prefs]
            .map(shellQuote).joined(separator: " ")
        let appleString = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        guard let script = NSAppleScript(source: "do shell script \"\(appleString)\" with administrator privileges") else { return "Could not start administrator authorization." }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        return error?[NSAppleScript.errorMessage] as? String
    }
}
