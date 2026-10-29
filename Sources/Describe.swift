import Foundation

/// Human-readable wording shared by the menu, `--status` and Copy Diagnostics.
enum Describe {
    static func power(_ p: PowerState) -> String {
        if p.sourceKnown == false { return "power source unknown" }
        let percent = p.batteryPercent.map { "\($0)%" }
        if p.onAC { return percent.map { "on AC (\($0))" } ?? "on AC" }
        return percent.map { "on battery \($0)" } ?? "on battery"
    }

    static func thermal(_ t: String) -> String {
        t == "nominal" ? "temp normal" : "temp \(t)"
    }

    static func displays(_ d: DisplayState) -> String {
        var parts: [String] = []
        if d.builtinActive { parts.append("built-in") }
        if d.external > 0 { parts.append("\(d.external) external") }
        if d.virtualActive { parts.append("virtual 1920×1080") }
        return parts.isEmpty ? "Displays: none active" : "Displays: " + parts.joined(separator: " + ")
    }

    static func report(_ s: Snapshot, app: AppState?) -> String {
        func row(_ label: String, _ value: String) -> String {
            "  " + label.padding(toLength: 16, withPad: " ", startingAt: 0) + value
        }
        var lines = ["Caffeine"]
        if let app {
            lines.append(row("App:", "running (pid \(app.pid)) · \(app.headline)"))
            if let problem = app.permissionProblem { lines.append(row("Problem:", problem)) }
            if let sim = app.simulation { lines.append(row("Simulation:", sim)) }
        } else {
            lines.append(row("App:", "not running"))
        }
        lines.append(row("Permission:", s.permissionRuleInstalled ? "installed (\(Pmset.sudoersPath))" : "not installed (run: Caffeine --permission-command)"))
        lines.append("This Mac")
        lines.append(row("Lid:", s.lidClosed.map { $0 ? "closed" : "open" } ?? "unknown"))
        lines.append(row("Power:", power(s.power)))
        lines.append(row("Temperature:", s.thermal))
        lines.append(row("Low Power Mode:", s.lowPowerMode ? "on" : "off"))
        if let observation = s.sleepObservation, observation.value == nil {
            lines.append(row("SleepDisabled:", "unknown (read failed)"))
            if let error = observation.error { lines.append(row("Read error:", error)) }
        } else {
            lines.append(row("SleepDisabled:", s.sleepDisabled ? "1 (lid close won't sleep)" : "0 (normal sleep)"))
        }
        lines.append(row("Displays:", "\(s.displays.active) active · built-in \(s.displays.builtinActive ? "on" : "off") · \(s.displays.external) external · virtual \(s.displays.virtualActive ? "on" : "off")"))
        lines.append("Last lid-closed test")
        lines.append("  " + ((app?.lastResult ?? Prefs.lastResult)?.summary ?? "none yet"))
        return lines.joined(separator: "\n")
    }
}
