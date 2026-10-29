import Foundation
import IOKit.pwr_mgt

enum Pmset {
    static let pmset = "/usr/bin/pmset"
    static let sudo = "/usr/bin/sudo"
    static let sudoersPath = "/etc/sudoers.d/caffeine"

    /// `pmset -g` lists "SleepDisabled 1" under "System-wide power settings" while the kernel flag is set.
    static func parseSleepDisabled(_ output: String) -> Bool {
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if fields.count >= 2, fields[0] == "SleepDisabled" { return fields[1] == "1" }
        }
        return false
    }

    struct SleepObservation: Codable, Equatable {
        var time: Date
        var value: Bool?
        var error: String?
    }
    static func parseSleepObservation(_ output: String, status: Int32 = 0, stderr: String = "", time: Date = Date()) -> SleepObservation {
        guard status == 0 else {
            return SleepObservation(time: time, value: nil,
                                    error: stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "pmset exited with \(status)" : stderr)
        }
        let fields = output.split(separator: "\n").map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }) }
        guard let row = fields.first(where: { $0.count >= 2 && $0[0] == "SleepDisabled" }), ["0", "1"].contains(String(row[1])) else {
            return SleepObservation(time: time, value: nil, error: "SleepDisabled was not present in pmset output")
        }
        return SleepObservation(time: time, value: row[1] == "1", error: nil)
    }
    static func observeSleepDisabled() -> SleepObservation {
        let result = Shell.run(pmset, ["-g"])
        return parseSleepObservation(result.stdout, status: result.status, stderr: result.stderr)
    }
    static func sleepDisabled() -> Bool { observeSleepDisabled().value ?? false }

    enum SetError: Error, Equatable {
        case needsPermission
        case failed(String)
    }

    /// Relies on the sudoers rule in /etc/sudoers.d/caffeine, which allows exactly
    /// `pmset -a disablesleep 0|1`. `sudo -n` never prompts; it fails instead.
    static func setSleepDisabled(_ disabled: Bool) -> Result<Void, SetError> {
        let r = Shell.run(sudo, ["-n", pmset, "-a", "disablesleep", disabled ? "1" : "0"])
        if r.ok { return .success(()) }
        if r.stderr.contains("password is required") || r.stderr.contains("not allowed") {
            return .failure(.needsPermission)
        }
        let message = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(.failed(message.isEmpty ? "pmset exited with \(r.status)" : message))
    }

    /// The console user may request sleep without root.
    @discardableResult
    static func sleepNow() -> Bool {
        Shell.run(pmset, ["sleepnow"]).ok
    }

    static func permissionCommand(user: String = NSUserName()) -> String {
        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
        return "f=$(mktemp) && printf '%s\\n' '\(rule)' > \"$f\" && /usr/sbin/visudo -cf \"$f\" && "
            + "sudo /usr/bin/install -m 0440 -o root -g wheel \"$f\" \(sudoersPath) && sudo /usr/sbin/visudo -c; rm -f \"$f\""
    }

    struct LogEvent {
        var date: Date
        var kind: String
        var detail: String
        var raw: String = ""

        var classification: String {
            if kind == "Sleep" { return "system_sleep" }
            if kind == "Wake" || kind == "DarkWake" { return "system_wake" }
            if detail.localizedCaseInsensitiveContains("Display is turned off") { return "display_sleep" }
            if detail.localizedCaseInsensitiveContains("Display is turned on") { return "display_wake" }
            return "power_event"
        }
        var fields: [String: Any] {
            ["time": ISO8601DateFormatter().string(from: date), "kind": kind,
             "classification": classification, "detail": detail, "raw": raw]
        }
    }

    /// Parses `pmset -g log` lines such as
    /// "2026-10-19 10:30:45 +1100 Sleep               \tEntering Sleep state due to ...".
    /// Pass `kinds` to skip date parsing for lines you don't care about (the log is ~25k lines).
    static func parseLog(_ text: String, kinds: Set<String>? = nil) -> [LogEvent] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        var events: [LogEvent] = []
        for line in text.split(separator: "\n") {
            guard line.count > 26 else { continue }
            let dateEnd = line.index(line.startIndex, offsetBy: 25)
            guard let date = formatter.date(from: String(line[..<dateEnd])) else { continue }
            let tail = line[dateEnd...].trimmingCharacters(in: .whitespaces)
            let kind: String
            let detail: String
            if let tab = tail.firstIndex(of: "\t") {
                kind = tail[..<tab].trimmingCharacters(in: .whitespaces)
                detail = tail[tail.index(after: tab)...].trimmingCharacters(in: .whitespaces)
            } else {
                let known = ["Wake Requests", "DarkWake", "Notification", "Sleep", "Wake", "Display"]
                guard let found = known.first(where: { tail.hasPrefix($0 + " ") || tail == $0 }) else { continue }
                kind = found
                detail = String(tail.dropFirst(found.count)).trimmingCharacters(in: .whitespaces)
            }
            if let kinds, !kinds.contains(kind) { continue }
            events.append(LogEvent(date: date, kind: kind, detail: detail, raw: String(line)))
        }
        return events
    }

    struct Evidence {
        var events: [LogEvent]
        var totalEvents: Int
        var systemSleepCount: Int
        var error: String?
        var capturedAt = Date()
        var fields: [String: Any] {
            ["events": events.map(\.fields), "totalMatchingEvents": totalEvents,
             "systemSleepCount": systemSleepCount, "error": error as Any? ?? NSNull(),
             "capturedAt": ISO8601DateFormatter().string(from: capturedAt)]
        }
    }
    static func scopedEvidence(_ text: String, from start: Date, to end: Date, status: Int32 = 0,
                               stderr: String = "", limit: Int = 40) -> Evidence {
        guard status == 0 else {
            return Evidence(events: [], totalEvents: 0, systemSleepCount: 0,
                            error: stderr.isEmpty ? "pmset log exited with \(status)" : stderr)
        }
        let matching = parseLog(text, kinds: ["Sleep", "Wake", "DarkWake", "Notification"])
            .filter { $0.date >= start && $0.date <= end && ($0.kind != "Notification" || $0.classification != "power_event") }
        return Evidence(events: Array(matching.suffix(max(0, limit))), totalEvents: matching.count,
                        systemSleepCount: matching.filter { $0.classification == "system_sleep" }.count, error: nil)
    }
    static func evidence(from start: Date, to end: Date) -> Evidence {
        let result = Shell.run(pmset, ["-g", "log"], timeout: 15)
        return scopedEvidence(result.stdout, from: start, to: end, status: result.status, stderr: result.stderr)
    }
    static func sleepEvents(from start: Date, to end: Date) -> [LogEvent] {
        evidence(from: start, to: end).events.filter { $0.kind == "Sleep" }
    }

}

/// Belt and braces next to SleepDisabled: also blocks idle sleep, and makes Caffeine
/// visible in `pmset -g assertions` and Activity Monitor while it is active.
final class SleepAssertion {
    static let name = "Caffeine: keeping this Mac awake"
    private var id: IOPMAssertionID = 0
    private let create: (inout IOPMAssertionID) -> IOReturn
    private let releaseAssertion: (IOPMAssertionID) -> IOReturn
    var isHeld: Bool { id != 0 }

    init(create: @escaping (inout IOPMAssertionID) -> IOReturn = { id in
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn), SleepAssertion.name as CFString, &id)
    }, release: @escaping (IOPMAssertionID) -> IOReturn = { IOPMAssertionRelease($0) }) {
        self.create = create
        self.releaseAssertion = release
    }

    /// Returns an error when the assertion could not be acquired; the next tick retries.
    @discardableResult func hold() -> IOReturn? {
        guard id == 0 else { return nil }
        var newID: IOPMAssertionID = 0
        let result = create(&newID)
        guard result == kIOReturnSuccess else { return result }
        id = newID
        return nil
    }

    func release() {
        guard id != 0 else { return }
        _ = releaseAssertion(id)
        id = 0
    }
}
