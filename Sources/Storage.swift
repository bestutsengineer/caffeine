import Foundation
import CryptoKit

enum Prefs {
    private static let defaults = UserDefaults.standard

    static var wantAwake: Bool {
        get { defaults.bool(forKey: "wantAwake") }
        set { defaults.set(newValue, forKey: "wantAwake") }
    }
    static var allowOnBattery: Bool {
        get { defaults.object(forKey: "allowOnBattery") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "allowOnBattery") }
    }
    static var doubleClickToToggle: Bool {
        get { defaults.object(forKey: "doubleClickToToggle") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "doubleClickToToggle") }
    }
    static var virtualDisplay: Bool {
        get { defaults.object(forKey: "virtualDisplay") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "virtualDisplay") }
    }
    static var minBatteryPercent: Int {
        get { max(5, min(80, defaults.object(forKey: "minBatteryPercent") as? Int ?? 20)) }
        set { defaults.set(max(5, min(80, newValue)), forKey: "minBatteryPercent") }
    }
    /// Preserve the old implicit-on setting on upgrades; new profiles start with it off.
    static func initialVirtualDisplayPreference(saved: Bool?, hasLegacyKeepAwakeSetting: Bool) -> Bool {
        saved ?? hasLegacyKeepAwakeSetting
    }
    static func migrateVirtualDisplayPreference() {
        guard defaults.object(forKey: "virtualDisplay") == nil else { return }
        defaults.set(initialVirtualDisplayPreference(saved: nil,
                     hasLegacyKeepAwakeSetting: defaults.object(forKey: "wantAwake") != nil), forKey: "virtualDisplay")
    }
    static var lastResult: LidSessionResult? {
        get { defaults.data(forKey: "lastResult").flatMap { try? JSONDecoder().decode(LidSessionResult.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "lastResult") }
    }
}

/// Power and display diagnostics, captured off the main thread.
struct Snapshot: Codable {
    var time: Date
    var lidClosed: Bool?
    var power: PowerState
    var thermal: String
    var lowPowerMode: Bool
    var sleepDisabled: Bool
    var displays: DisplayState
    var permissionRuleInstalled: Bool
    var sleepObservation: Pmset.SleepObservation? = nil
    var systemTiming: SystemTiming? = nil

    static func capture() -> Snapshot {
        let observation = Pmset.observeSleepDisabled()
        return Snapshot(time: Date(),
                 lidClosed: Sensors.lidClosed(),
                 power: Sensors.power(),
                 thermal: Sensors.thermal(),
                 lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                 sleepDisabled: observation.value ?? false,
                 displays: Sensors.displays(),
                 permissionRuleInstalled: FileManager.default.fileExists(atPath: Pmset.sudoersPath), sleepObservation: observation,
                 systemTiming: SystemTimingReader.read())
    }
}

/// What the running app publishes for the CLI (and for testing): written to Application Support.
struct AppState: Codable {
    var time: Date
    var pid: Int32
    var headline: String
    var wantAwake: Bool
    var active: Bool
    var sleepDisabled: Bool
    var assertionHeld: Bool
    var virtualDisplayActive: Bool
    var guardReason: String?
    var permissionProblem: String?
    var lidClosed: Bool
    var onAC: Bool
    var batteryPercent: Int?
    var thermal: String
    var simulation: String?
    var lastResult: LidSessionResult?
    var menu: [String]
    var snapshot: Snapshot?
    var lastCommandID: String? = nil
    var diagnostics: DiagnosticContext? = nil
    var virtualDisplayOwned: Bool? = nil
    var runID: String? = nil

    /// The app's published state, if that app process is still alive.
    static func running() -> AppState? {
        guard let state = load(), kill(state.pid, 0) == 0 else { return nil }
        return state
    }

    static let url = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Caffeine/state.json")

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: .atomic)
    }

    static func load() -> AppState? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url)).flatMap { try? decoder.decode(AppState.self, from: $0) }
    }
}

enum EventLog {
    static let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/Caffeine")
    static let file = directory.appendingPathComponent("events.log")
    static let runID = UUID().uuidString
    static let identity: [String: Any] = {
        let bundle = Bundle.main
        let hash = bundle.executableURL.flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
            .map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        return ["appVersion": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                "buildNumber": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                "sourceRevision": bundle.object(forInfoDictionaryKey: "CaffeineSourceRevision") as? String ?? "unknown",
                "executableSHA256": hash as Any? ?? NSNull()]
    }()
    private static let queue = DispatchQueue(label: "caffeine.eventlog")
    private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func flush() { queue.sync {} }

    /// One JSON object per line, so the history is easy to grep or load.
    static func write(_ event: String, _ fields: [String: Any] = [:]) {
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        queue.async {
            var record = fields
            record["t"] = stamp.string(from: now)
            record["event"] = event
            record["runID"] = runID
            record["pid"] = getpid()
            record["uptimeSeconds"] = uptime
            guard var line = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
            line.append(0x0A)
            let fm = FileManager.default
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size > 5_000_000 {
                let old = directory.appendingPathComponent("events.1.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: file, to: old)
            }
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write(line)
                try? handle.close()
            } else {
                try? line.write(to: file)
            }
        }
    }
}

/// Optional LaunchAgent: starts Caffeine at login and relaunches it if it ever crashes
/// (a crash would otherwise leave SleepDisabled set with no guards watching).
enum LoginItem {
    static let label = "local.caffeine.agent"
    static var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }
    static var launchedByAgent: Bool { ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label }

    static func enable() throws {
        guard let executable = Bundle.main.executablePath else { return }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],   // a normal Quit stays quit; a crash relaunches
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)
        // Already running under the agent (re-enabled after a disable): the job is still loaded.
        guard !launchedByAgent else { return }
        // Loading the job starts the agent's own instance, which asks this one to hand over.
        _ = Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        _ = Shell.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    /// Starts the agent's instance (loading the job first if needed). Used when the app is opened
    /// by hand while Start at Login is on, so the running copy is always the crash-protected one.
    static func kickstart() -> Bool {
        let domain = "gui/\(getuid())"
        _ = Shell.run("/bin/launchctl", ["bootstrap", domain, plistURL.path])   // fails harmlessly if loaded
        return Shell.run("/bin/launchctl", ["kickstart", "\(domain)/\(label)"]).ok
    }

    /// Removing the plist is enough: the loaded job only relaunches after a crash, and is gone at next login.
    static func disable() {
        try? FileManager.default.removeItem(at: plistURL)
    }
}
