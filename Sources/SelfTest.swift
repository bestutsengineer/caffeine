import AppKit

enum SelfTest {
    private static var failures = 0

    private static func check(_ condition: Bool, _ name: String) {
        print(condition ? "PASS" : "FAIL", name)
        if !condition { failures += 1 }
    }

    private static func succeeded(_ result: Result<Void, Pmset.SetError>) -> Bool {
        if case .success = result { return true }
        print("     ->", result)
        return false
    }

    static func run(live: Bool, sensors: Bool = false) -> Int32 {
        guardTests()
        parserTests()
        diagnosticTests()
        virtualDisplayPolicyTests()
        settingsTests()
        timingAndGestureTests()
        shellTimeoutTest()
        trackerTests()
        if sensors { sensorTests() }
        if live { liveTests() }
        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
        return failures == 0 ? 0 : 1
    }

    private static func timingAndGestureTests() {
        print("== Settings timing and icon gestures")
        let policy = SystemTiming.parse("Battery Power:\n sleep 2\n displaysleep 10\nAC Power:\n sleep 0\n displaysleep 60\n",
                                        password: "screenLock delay is immediate", saver: "300\n")
        check(policy.batterySleepMinutes == 2 && policy.acSleepMinutes == 0, "separate battery/AC sleep settings")
        check(policy.batteryDisplayMinutes == 10 && policy.acDisplayMinutes == 60, "separate display timeout from system sleep")
        check(policy.screenSaverSeconds == 300 && policy.passwordDelaySeconds == 0, "screen saver trigger and immediate password remain distinct")
        check(policy.rows(onAC: true).contains("Idle sleep when Caffeine is off: Never (configured)"), "zero system idle timeout means configured never")
        check(policy.rows(onAC: false).contains("Idle sleep when Caffeine is off: 2 min"), "current power source selects correct timeout")
        let delayed = SystemTiming.parse("", password: "screenLock delay is 5 minutes", saver: "")
        check(delayed.passwordDelaySeconds == 300, "password delay units parsed")
        let off = SystemTiming.parse("", password: "screenLock is off", saver: "0")
        check(off.passwordDelaySeconds == -1 && off.screenSaverSeconds == 0, "disabled password and screen saver policies distinguished")
        let missing = SystemTiming.parse("sleep 5", password: "unrecognized output", saver: "error")
        check(missing.acSleepMinutes == nil && missing.passwordDelaySeconds == nil && missing.screenSaverSeconds == nil,
              "unreadable settings never invent a timeout")
        check(IconClick.action(clickCount: 1, rightButton: false, enabled: true) == .deferMenu, "single click waits for double-click disambiguation")
        check(IconClick.action(clickCount: 2, rightButton: false, enabled: true) == .toggle, "double click toggles once")
        check(IconClick.action(clickCount: 3, rightButton: false, enabled: true) == .ignore, "triple click does not toggle twice")
        check(IconClick.action(clickCount: 1, rightButton: true, enabled: true) == .showMenu, "right click opens menu immediately")
        check(IconClick.action(clickCount: 2, rightButton: false, enabled: false) == .showMenu, "disabled gesture only opens menu")
        let legacyConfig = Data(#"{"wantAwake":true,"allowOnBattery":true,"minBatteryPercent":10,"virtualDisplay":true,"startAtLogin":true}"#.utf8)
        check((try? JSONDecoder().decode(KeepAwakeConfiguration.self, from: legacyConfig)) != nil,
              "legacy running-app state decodes before guarded upgrade")
        check(CLI.validSetting("doubleClickToToggle=1") && !CLI.validSetting("doubleClickToToggle=2"), "gesture CLI setting validated")
    }

    private static func guardTests() {
        print("== Guards")
        let base = GuardInput(lidClosed: false, onAC: true, batteryPercent: 100, thermal: "nominal",
                              allowOnBattery: false, minBatteryPercent: 20)
        func eval(_ change: (inout GuardInput) -> Void) -> GuardDecision {
            var input = base
            change(&input)
            return Guards.evaluate(input)
        }
        check(eval { _ in } == .allow, "AC, lid open → allow")
        check(eval { $0.lidClosed = true } == .allow, "AC, lid closed → allow")
        check(eval { $0.lidClosed = true; $0.batteryPercent = 5 } == .allow, "AC with low battery (charging) → allow")
        check(eval { $0.onAC = false; $0.batteryPercent = 80 } == .allow, "battery 80%, lid open → allow")
        check(eval { $0.onAC = false; $0.lidClosed = true; $0.batteryPercent = 80 } == .block("lid closed on battery"),
              "battery 80%, lid closed → block (bag guard)")
        check(eval { $0.onAC = false; $0.lidClosed = true; $0.batteryPercent = 80; $0.allowOnBattery = true } == .allow,
              "battery 80%, lid closed, battery allowed → allow")
        check(eval { $0.onAC = false; $0.lidClosed = true; $0.batteryPercent = 20; $0.allowOnBattery = true } == .block("battery at 20%"),
              "battery 20%, battery allowed → block at threshold")
        check(eval { $0.onAC = false; $0.allowOnBattery = true; $0.minBatteryPercent = 10; $0.batteryPercent = 10 } == .block("battery at 10%"),
              "custom 10% cutoff pauses at threshold")
        check(eval { $0.onAC = false; $0.lidClosed = true; $0.allowOnBattery = true; $0.minBatteryPercent = 10; $0.batteryPercent = 11 } == .allow,
              "custom 10% cutoff allows 11%")
        check(eval { $0.onAC = false; $0.batteryPercent = 12 } == .block("battery at 12%"), "battery 12%, lid open → block")
        check(eval { $0.thermal = "serious" } == .allow, "thermal serious → allow")
        check(eval { $0.sensorsKnown = false } == .block("power or lid sensor unavailable"), "missing power/lid sensor → block")
        check(eval { $0.onAC = false; $0.batteryPercent = nil } == .block("battery level unavailable"), "unknown battery level → block")
        check(eval { $0.thermal = "unknown" } == .block("temperature unavailable"), "unknown thermal state → block")
        check(eval { $0.thermal = "critical" } == .block("Mac is critically hot"), "thermal critical → block")
    }

    private static func parserTests() {
        print("== Parsers")
        check(Pmset.parseSleepDisabled("System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n sleep 0\n"),
              "pmset -g with SleepDisabled 1")
        check(!Pmset.parseSleepDisabled("System-wide power settings:\nCurrently in use:\n standby 1\n"),
              "pmset -g without SleepDisabled")
        check(!Pmset.parseSleepDisabled(" SleepDisabled\t\t0\n"), "pmset -g with SleepDisabled 0")

        let log = """
            2026-10-19 10:30:45 +1100 Sleep               \tEntering Sleep state due to 'Maintenance Sleep' Using AC
            2026-10-19 10:30:47 +1100 Wake Requests       \t[*process=dasd request=SleepService]
            2026-10-19 10:41:48 +1100 Wake                \tWake from Deep Idle [CDNVA] : due to lid
            not a log line
            """
        let all = Pmset.parseLog(log)
        check(all.map(\.kind) == ["Sleep", "Wake Requests", "Wake"], "pmset log kinds parsed")
        check(Pmset.parseLog(log, kinds: ["Sleep"]).count == 1, "pmset log filtered to Sleep")
        let parsed = all.first?.date ?? .distantPast
        let expected = ISO8601DateFormatter().date(from: "2026-10-19T10:30:45+11:00")!
        check(parsed == expected, "pmset log timestamp parsed with zone")
    }

    private static func diagnosticTests() {
        print("== Causal diagnostics")
        let text = """
            2026-10-29 10:00:00 +1100 Sleep               \tEntering Sleep state due to 'Clamshell Sleep' Using Batt
            2026-10-29 11:09:15 +1100 Notification        \tDisplay is turned off                                                      \t
            2026-10-29 11:10:00 +1100 Wake Requests       \tSleepService scheduled a wake
            2026-10-29 11:33:44 +1100 Notification        \tDisplay is turned on                                                       \t
            2026-10-29 11:34:00 +1100 Sleep               \tEntering Sleep state due to 'Software Sleep' Using Batt
            2026-10-29 11:35:00 +1100 Wake                \tWake from Deep Idle : due to EC.LidOpen
            2026-10-29 11:36:00 +1100 Notification Display is turned off
            """
        let events = Pmset.parseLog(text)
        check(events.filter { $0.classification == "system_sleep" }.count == 2, "only Sleep category counts as system sleep")
        check(events.filter { $0.classification == "display_sleep" }.count == 2, "tabbed and plain display-off notifications are classified separately")
        check(events.first { $0.classification == "display_wake" }?.detail == "Display is turned on", "real display-on fixture is trimmed correctly")
        check(events.last?.raw.hasSuffix("Notification Display is turned off") == true, "evidence preserves the raw reason line")
        let formatter = ISO8601DateFormatter()
        let start = formatter.date(from: "2026-10-29T11:00:00+11:00")!
        let end = formatter.date(from: "2026-10-29T11:33:50+11:00")!
        let screenOnly = Pmset.scopedEvidence(text, from: start, to: end)
        check(screenOnly.systemSleepCount == 0 && screenOnly.events.count == 2,
              "display off/on plus a wake request does not imply system sleep")
        let bounded = Pmset.scopedEvidence(text, from: start, to: end + 120, limit: 1)
        check(bounded.events.count == 1 && bounded.totalEvents == 4 && bounded.systemSleepCount == 1,
              "bounded excerpt preserves the full scoped sleep count")
        check(bounded.events.first?.detail.contains("EC.LidOpen") == true, "scoped excerpt retains the wake cause")
        let failedObservation = Pmset.parseSleepObservation("", status: 1, stderr: "permission denied")
        let failedSnapshot = Snapshot(time: start, lidClosed: true, power: PowerState(onAC: false, batteryPercent: 31),
                                      thermal: "nominal", lowPowerMode: false, sleepDisabled: false,
                                      displays: DisplayState(active: 0, builtinActive: false, external: 0, virtualActive: false),
                                      permissionRuleInstalled: true, sleepObservation: failedObservation)
        let report = Describe.report(failedSnapshot, app: nil)
        check(report.contains("unknown (read failed)") && !report.contains("0 (normal sleep)"),
              "status cannot call an unreadable sleep setting normal sleep")
        let failed = Pmset.scopedEvidence("", from: start, to: end, status: 1, stderr: "log unavailable")
        check(failed.error == "log unavailable", "unavailable power log is explicit")
        check(Pmset.parseSleepObservation("SleepDisabled 0").value == false, "observed normal sleep is false")
        check(Pmset.parseSleepObservation("sleep 1").value == nil, "missing SleepDisabled observation stays unknown")
        check(Pmset.parseSleepObservation("SleepDisabled 1", status: 1).value == nil, "failed read cannot claim SleepDisabled true")

        let config = KeepAwakeConfiguration(wantAwake: true, allowOnBattery: true, minBatteryPercent: 10,
                                            virtualDisplay: true, startAtLogin: true)
        let displays = DisplayState(active: 0, builtinActive: false, external: 0, virtualActive: false,
                                    online: 1, virtualOnline: true, builtinOnline: false, activeReadStatus: 0, onlineReadStatus: 0)
        let base = DiagnosticContext(lidClosed: true, power: PowerState(onAC: false, batteryPercent: 31),
                                     thermal: "nominal", sensorsKnown: true, configuration: config,
                                     guardReason: nil, cachedSleepDisabled: true,
                                     sleepObservation: Pmset.SleepObservation(time: start, value: true, error: nil),
                                     assertionHeld: true, virtualDisplayOwned: true, displays: displays,
                                     screensAsleep: nil, sessionActive: nil, screenLocked: nil)
        check(base.fields["virtualDisplayOwned"] as? Bool == true && base.displays.virtualActive == false,
              "owned virtual object and inactive display remain distinct")
        check(base.fields["screenLocked"] is NSNull && base.fields["sessionActive"] is NSNull,
              "unknown lock and session state are not invented")
        check(JSONSerialization.isValidJSONObject(base.fields), "common context can be encoded as JSON")
        var changed = base
        changed.sleepObservation?.time = end
        check(changed.changes(from: base).isEmpty, "unchanged sensor refresh stays quiet")
        changed = base; changed.configuration.minBatteryPercent = 20
        check(changed.changes(from: base) == ["configuration_transition"], "cutoff changes have an explicit configuration event")
        changed = base; changed.displays.active = 1
        check(changed.changes(from: base) == ["display_transition"], "actual active display changes are logged")
        changed = base; changed.sleepObservation?.value = false
        check(changed.changes(from: base) == ["protection_transition"], "observed sleep-setting changes are logged")
        changed = base; changed.power.onAC = true
        check(changed.changes(from: base) == ["power_transition"], "power-source transitions are logged")
        changed = base; changed.thermal = "serious"
        check(changed.changes(from: base) == ["thermal_transition"], "temperature transitions are logged")
        check(!TickGap(wallSeconds: 5, uptimeSeconds: 5).shouldLog, "normal five-second beats do not spam the log")
        let clockJump = TickGap(wallSeconds: 605, uptimeSeconds: 5)
        check(clockJump.shouldLog && clockJump.wallMinusUptimeSeconds == 600, "wall-clock jumps are distinct from monotonic scheduling gaps")
        check(TickGap(wallSeconds: 60, uptimeSeconds: 60).shouldLog, "long monotonic scheduling stall is recorded")
        let unknown = LidSessionResult(closedAt: start, openedAt: end, maxGapSeconds: 5, sleepEvents: 0,
                                       activeThroughout: true, sleepLogAvailable: false)
        check(!unknown.stayedAwake && !unknown.failed && unknown.summary.contains("log unavailable"),
              "missing sleep evidence cannot be reported as a pass or definite failure")
    }

    private static func virtualDisplayPolicyTests() {
        print("== Headless display lifecycle policy")
        let headless = DisplayState(active: 0, builtinActive: false, external: 0, virtualActive: false,
                                    online: 1, virtualOnline: false, builtinOnline: true,
                                    activeReadStatus: 0, onlineReadStatus: 0, externalOnline: 0)
        func plan(enabled: Bool = true, protection: Bool = true, lid: Bool? = true,
                  displays: DisplayState? = nil) -> VirtualDisplayEligibility {
            VirtualDisplayPolicy.evaluate(enabled: enabled, protectionActive: protection,
                                          lidClosed: lid, displays: displays ?? headless)
        }
        check(plan() == .headless && plan().shouldExist, "stable closed headless session can use an opted-in display")
        check(plan(enabled: false) == .disabled, "disabled option removes/suppresses the virtual display")
        check(plan(protection: false) == .protectionInactive, "guard pause or Keep Awake off removes/suppresses the display")
        check(plan(lid: nil) == .lidUnknown, "unknown lid state cannot create a desktop")
        check(plan(lid: false) == .lidOpen, "lid reopen removes the headless display")
        var display = headless
        display.builtinActive = true; display.active = 1
        check(plan(displays: display) == .builtinDisplayActive, "no extra desktop while the built-in screen is active")
        display = headless; display.externalOnline = 1; display.online = 2
        check(plan(displays: display) == .externalMonitorConnected && display.external == 0,
              "sleeping external monitor still prevents a second desktop")
        display.external = 1; display.active = 1
        check(plan(displays: display) == .externalMonitorConnected, "active external monitor prevents a second desktop")
        display = headless; display.activeReadStatus = 1000
        check(plan(displays: display) == .displayInformationUnavailable, "failed active-screen enumeration cannot create a desktop")
        display = headless; display.onlineReadStatus = 1000
        check(plan(displays: display) == .displayInformationUnavailable, "failed online-screen enumeration cannot create a desktop")
        display = headless; display.externalOnline = nil
        check(plan(displays: display) == .displayInformationUnavailable, "legacy/unknown external-monitor count fails closed")
        display = headless; display.virtualActive = true; display.virtualOnline = true
        check(plan(displays: display).shouldExist, "the owned virtual display does not masquerade as an external monitor")
        let lifecycle = [plan(), plan(lid: false), plan(), plan(displays: DisplayState(active: 1, builtinActive: false,
                         external: 1, virtualActive: true, online: 2, virtualOnline: true,
                         activeReadStatus: 0, onlineReadStatus: 0, externalOnline: 1)), plan(protection: false)]
        check(lifecycle.map(\.shouldExist) == [true, false, true, false, false],
              "open lid, external hotplug and protection loss each remove the virtual desktop")
        check(VirtualDisplayPolicy.shouldPauseForSession(eligibility: .builtinDisplayActive, secondsSinceCreation: 1),
              "private-display setup waking a real screen pauses repeated creation")
        check(!VirtualDisplayPolicy.shouldPauseForSession(eligibility: .externalMonitorConnected, secondsSinceCreation: 1),
              "normal external hotplug does not falsely diagnose private-API instability")
        check(!VirtualDisplayPolicy.shouldPauseForSession(eligibility: .builtinDisplayActive, secondsSinceCreation: nil),
              "an unowned setup cannot be blamed for real-screen activation")
        check(!VirtualDisplayPolicy.shouldPauseForSession(eligibility: .builtinDisplayActive, secondsSinceCreation: 20),
              "later physical-screen activity follows normal removal policy")
        check(VirtualDisplayPolicy.settleSeconds >= 2, "headless eligibility must settle before desktop creation")
        check(Prefs.initialVirtualDisplayPreference(saved: nil, hasLegacyKeepAwakeSetting: false) == false,
              "new installations start with experimental display off")
        check(Prefs.initialVirtualDisplayPreference(saved: nil, hasLegacyKeepAwakeSetting: true),
              "legacy implicit-on configuration is preserved on upgrade")
        check(Prefs.initialVirtualDisplayPreference(saved: false, hasLegacyKeepAwakeSetting: true) == false,
              "an explicit disabled choice is preserved")
        check(Prefs.initialVirtualDisplayPreference(saved: true, hasLegacyKeepAwakeSetting: false),
              "an explicit enabled choice is preserved")
        check(CaffeineHelp.securityText.contains("does not log you out") && CaffeineHelp.securityText.contains("mounted FileVault")
                && CaffeineHelp.securityText.contains("does not") && !CaffeineHelp.securityText.contains("encrypts all files"),
              "on-demand explanation distinguishes locking from encryption/logout without a blanket promise")
        check(CaffeineHelp.appleSecurityURL.host == "support.apple.com", "security explanation links to Apple's primary guide")
    }

    private static func shellTimeoutTest() {
        print("== Process timeout")
        let started = Date()
        let result = Shell.run("/bin/sh", ["-c", "trap '' TERM; exec /bin/sleep 20"], timeout: 0.2)
        check(!result.ok && Date().timeIntervalSince(started) < 4,
              "SIGTERM-ignoring process is killed within the timeout bound")
    }

    private static func settingsTests() {
        print("== Settings")
        for value in ["minBatteryPercent=5", "minBatteryPercent=10", "minBatteryPercent=80", "allowOnBattery=1", "virtualDisplay=0"] {
            check(CLI.validSetting(value), "accept \(value)")
        }
        for value in ["minBatteryPercent=4", "minBatteryPercent=81", "minBatteryPercent=-1", "minBatteryPercent=x", "allowOnBattery=2", "unknown=1", "virtualDisplay="] {
            check(!CLI.validSetting(value), "reject \(value)")
        }
    }

    private static func trackerTests() {
        print("== Lid tracker")
        let tracker = LidTracker()
        let t0 = Date()
        check(tracker.beat(now: t0, lidClosed: false, active: true) == .none, "open lid: nothing")
        check(tracker.beat(now: t0 + 5, lidClosed: true, active: true) == .closed, "close detected")
        check(tracker.beat(now: t0 + 10, lidClosed: true, active: true) == .none, "still closed")
        _ = tracker.beat(now: t0 + 400, lidClosed: true, active: true)   // 390 s gap: the Mac slept
        if case .opened(let session) = tracker.beat(now: t0 + 405, lidClosed: false, active: true) {
            check(Int(session.maxGap) == 390, "gap of 390 s recorded")
            let result = LidSessionResult(closedAt: session.closedAt, openedAt: session.openedAt,
                                          maxGapSeconds: Int(session.maxGap), sleepEvents: 0, activeThroughout: true)
            check(!result.stayedAwake, "long gap counts as not awake")
        } else {
            check(false, "open detected")
        }
        let awake = LidSessionResult(closedAt: t0, openedAt: t0 + 1500, maxGapSeconds: 6, sleepEvents: 0, activeThroughout: true)
        check(awake.stayedAwake && awake.minutes == 25, "25 min with 6 s gaps counts as awake")
        let guarded = LidSessionResult(closedAt: t0, openedAt: t0 + 953, maxGapSeconds: 949, sleepEvents: 1,
                                       activeThroughout: false, pausedReason: "lid closed on battery")
        check(!guarded.failed && guarded.summary.hasSuffix("slept as expected (lid closed on battery)"),
              "guard sleep reads as expected, not a failure")
        let older = LidSessionResult(closedAt: t0, openedAt: t0 + 953, maxGapSeconds: 949, sleepEvents: 1, activeThroughout: false)
        check(!older.failed, "saved result without a reason, Caffeine inactive → not a failure")
        let broken = LidSessionResult(closedAt: t0, openedAt: t0 + 953, maxGapSeconds: 949, sleepEvents: 1, activeThroughout: true)
        check(broken.failed && broken.summary.hasSuffix("slept 1× while Caffeine was on"), "sleep while active → failure")
    }

    private static func sensorTests() {
        print("== Sensors (read-only)")
        let lid = Sensors.lidClosed()
        check(lid != nil, "lid state readable (\(lid.map { $0 ? "closed" : "open" } ?? "nil"))")
        let power = Sensors.power()
        check(power.batteryPercent != nil, "battery readable (\(Describe.power(power)))")
        let displays = Sensors.displays()
        check(displays.active >= 0, "displays readable (\(Describe.displays(displays)))")
    }

    private static func liveTests() {
        print("== Live (toggles SleepDisabled, then restores it)")
        if let app = AppState.running() {
            print("SKIP Caffeine app is running (pid \(app.pid)); quit it first so the two don't fight over the setting")
            failures += 1
            return
        }
        guard Sensors.lidClosed() == false else {
            check(false, "live sleep-setting tests require an open lid")
            return
        }
        let original = Pmset.sleepDisabled()
        print("     original SleepDisabled = \(original ? 1 : 0)")
        defer {
            _ = Pmset.setSleepDisabled(original)
            check(Pmset.sleepDisabled() == original, "restored original SleepDisabled = \(original ? 1 : 0)")
        }
        check(succeeded(Pmset.setSleepDisabled(true)), "sudo -n pmset -a disablesleep 1 (no password)")
        check(Pmset.sleepDisabled(), "pmset -g now shows SleepDisabled 1")

        let assertion = SleepAssertion()
        assertion.hold()
        let held = Shell.run(Pmset.pmset, ["-g", "assertions"]).stdout
        check(held.contains(SleepAssertion.name), "assertion visible in pmset -g assertions")
        assertion.release()
        let released = Shell.run(Pmset.pmset, ["-g", "assertions"]).stdout
        check(!released.contains(SleepAssertion.name), "assertion released")

        check(succeeded(Pmset.setSleepDisabled(false)), "sudo -n pmset -a disablesleep 0 (no password)")
        check(!Pmset.sleepDisabled(), "pmset -g now shows normal sleep")
        let sneaky = Shell.run(Pmset.sudo, ["-n", Pmset.pmset, "-a", "sleep", "0"])
        check(!sneaky.ok, "rule is narrow: sudo -n pmset -a sleep 0 is refused")
    }

    static func virtualDisplay() -> Int32 {
        _ = NSApplication.shared
        print("== Virtual display (appears for ~2 s)")
        let display = VirtualDisplay()
        check(display.create(), "created")
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        let during = Sensors.displays()
        check(during.virtualActive, "listed as an active display (\(Describe.displays(during)))")
        display.destroy()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let after = Sensors.displays()
        check(!after.virtualActive, "removed (\(Describe.displays(after)))")
        return failures == 0 ? 0 : 1
    }
}
