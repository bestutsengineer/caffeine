import AppKit

enum CLI {
    static let usage = """
        Caffeine: keep this Mac awake with the lid closed.

        Usage: Caffeine [command]
          (no command)             run the menu bar app
          --status                 full status report (works without the app running)
          --on | --off             turn lid-closed awake on or off in the running app
          --refresh                make the running app re-check everything now
          --set key=0|1            virtualDisplay, allowOnBattery, startAtLogin, doubleClickToToggle
          --set minBatteryPercent=5..80   battery cutoff (default 15%)
          --quit                   quit the app (restores normal sleep)
          --handoff                preserve sleep setting for a guarded app update
          --selftest [--sensors]   offline tests; --sensors adds read-only hardware checks
          --selftest --live        also toggles SleepDisabled (lid must be open)
          --test-virtual-display   create the virtual display for 2 s, then remove it
          --permission-command     print the one-time sudoers setup command
        """

    static func run(_ args: [String]) -> Int32 {
        let value = args.dropFirst().first ?? ""
        switch args.first ?? "" {
        case "--status":
            print(Describe.report(Snapshot.capture(), app: AppState.running()))
            return 0
        case "--on": return send("on")
        case "--off": return send("off")
        case "--refresh": return send("refresh")
        case "--quit": return send("quit")
        case "--handoff": return send("handoff")
        case "--set":
            guard validSetting(value) else {
                fputs("Use minBatteryPercent=5..80 or virtualDisplay|allowOnBattery|startAtLogin|doubleClickToToggle=0|1.\n", stderr)
                return 64
            }
            return send("set:" + value)
        case "--sim": return send("sim:" + (value.isEmpty ? "clear" : value))
        case "--selftest": return SelfTest.run(live: args.contains("--live"), sensors: args.contains("--sensors"))
        case "--test-virtual-display": return SelfTest.virtualDisplay()
        case "--permission-command":
            print(Pmset.permissionCommand())
            return 0
        case "--help", "-h":
            print(usage)
            return 0
        default:
            fputs(usage + "\n", stderr)
            return 64
        }
    }

    static func validSetting(_ value: String) -> Bool {
        let pair = value.split(separator: "=", omittingEmptySubsequences: false)
        guard pair.count == 2 else { return false }
        if pair[0] == "minBatteryPercent" { return Int(pair[1]).map { (5...80).contains($0) } ?? false }
        return ["virtualDisplay", "allowOnBattery", "startAtLogin", "doubleClickToToggle"].contains(String(pair[0])) && ["0", "1"].contains(String(pair[1]))
    }

    /// Posts a command to the running app and waits until it publishes state tagged with our ID.
    static func send(_ command: String) -> Int32 {
        guard AppState.running() != nil else {
            fputs("Caffeine isn't running. Open it first: open -a Caffeine\n", stderr)
            return 1
        }
        let id = UUID().uuidString
        DistributedNotificationCenter.default().postNotificationName(AppController.command, object: "\(command)@\(id)",
                                                                     userInfo: nil, deliverImmediately: true)
        if command == "quit" || command == "handoff" { return 0 }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let state = AppState.load(), state.lastCommandID == id {
                print(state.headline)
                if let problem = state.permissionProblem { print("Problem: \(problem)") }
                return 0
            }
            usleep(150_000)
        }
        fputs("No answer from the app within 10 s.\n", stderr)
        return 1
    }
}
