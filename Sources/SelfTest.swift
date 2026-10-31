import AppKit

private final class FakeHotspotDevice: NSObject {
    @objc let deviceName: String
    init(_ name: String) { deviceName = name }
}

private final class FakeHotspotSession: NSObject {
    @objc weak var delegate: NSObject?
    var requestedName: String?
    var failFirst = false
    var usedFallback = false
    @objc func startBrowsing() {
        _ = delegate?.perform(NSSelectorFromString("updatedFoundDeviceList:"),
                              with: [FakeHotspotDevice("Other phone"), FakeHotspotDevice("Recent phone")] as NSArray)
    }
    @objc func stopBrowsing() {}
    @objc func enableRemoteHotspotForDevice(_ device: FakeHotspotDevice,
                                           withCompletionHandler completion: @escaping (AnyObject?, AnyObject?) -> Void) {
        requestedName = device.deviceName
        if failFirst { completion(nil, nil) }
        else { completion(device.deviceName as NSString, "test-only" as NSString) }
    }
    @objc func enableHotspotForDevice(_ device: FakeHotspotDevice,
                                    withCompletionHandler completion: @escaping (AnyObject?, AnyObject?) -> Void) {
        usedFallback = true
        completion(device.deviceName as NSString, "test-only" as NSString)
    }
}

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
        thermalSafetyTests()
        inactivitySleepTests()
        capsSwitchTests()
        restartScheduleTests()
        sleepOwnershipTests()
        assertionTests()
        hotspotPolicyTests()
        parserTests()
        diagnosticTests()
        virtualDisplayPolicyTests()
        settingsTests()
        timingAndGestureTests()
        performanceRetentionTests()
        shellTimeoutTest()
        trackerTests()
        if sensors { sensorTests() }
        if live { liveTests() }
        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
        return failures == 0 ? 0 : 1
    }

    private static func restartScheduleTests() {
        print("== Scheduled restart")
        let normal = RestartSchedule.parseTime("05:00")
        check(normal?.0 == 5 && normal?.1 == 0, "parse 05:00")
        check(RestartSchedule.parseTime("23:59") != nil, "accept end of day")
        check(RestartSchedule.parseTime("24:00") == nil && RestartSchedule.parseTime("5:60") == nil, "reject invalid clock times")
        check(RestartSchedule.parseTime("5:00;reboot") == nil && RestartSchedule.parseTime("5:") == nil, "reject extra input")
    }

    private static func capsSwitchTests() {
        print("== Caps Lock switch")
        let src = CapsMappingPolicy.sourceKey, dst = CapsMappingPolicy.destinationKey
        let other: [String: UInt64] = [src: 0x700000004, dst: 0x700000005]
        let original: [String: UInt64] = [src: CapsMappingPolicy.caps, dst: 0x700000029]
        let replacement: [String: UInt64] = [src: CapsMappingPolicy.caps, dst: 0x70000006f]
        let mapped = CapsMappingPolicy.replacingCaps(in: [other, original], with: [replacement])
        check(mapped == [other, replacement], "Caps-only remapping preserves unrelated keyboard mappings")
        check(CapsMappingPolicy.replacingCaps(in: mapped, with: [original]) == [other, original], "disabling restores the original Caps mapping")
        check(CapsMappingPolicy.owns(mapped, destination: 0x70000006f), "mapping ownership is verified")
        check(!CapsMappingPolicy.owns([original], destination: 0x70000006f), "external Caps mapping is not claimed")
        check(CapsSwitchPolicy.light(on: true, timer: false, phase: false), "active light is on between marker pulses")
        check(!CapsSwitchPolicy.light(on: true, timer: false, phase: false, markerPulse: true), "five-second marker briefly turns the light off")
        check(CapsSwitchPolicy.light(on: true, timer: true, phase: true, markerPulse: true), "timer blinking takes priority over five-second marker")
        check(!CapsSwitchPolicy.light(on: true, timer: true, phase: false) && CapsSwitchPolicy.light(on: true, timer: true, phase: true), "timer blinks the light without toggling modifier")
        check(!CapsSwitchPolicy.light(on: false, timer: true, phase: true), "off state leaves indicator off")
    }

    private static func inactivitySleepTests() {
        print("== Inactivity sleep")
        let suite = "local.caffeine.selftest.idle.\(UUID().uuidString)"
        if let defaults = UserDefaults(suiteName: suite) {
            defer { defaults.removePersistentDomain(forName: suite) }
            let first = IdleDurationStore(defaults: defaults)
            check(first.remember && first.minutes == 0, "duration is remembered by default")
            first.minutes = 30
            check(IdleDurationStore(defaults: defaults).minutes == 30, "remembered duration survives a new session")
            first.remember = false
            check(first.minutes == 30 && IdleDurationStore(defaults: defaults).minutes == 0, "disabling memory keeps this session but resets the next")
            first.minutes = 15
            check(IdleDurationStore(defaults: defaults).minutes == 0, "session duration is not persisted")
            first.remember = true
            check(IdleDurationStore(defaults: defaults).minutes == 15, "re-enabling memory saves the current selection")
        } else { check(false, "isolated preferences are available") }
        var gate = InactivityPowerGate()
        let plugged = gate.update(batteryOnly: true, sourceKnown: true, onAC: true)
        check(!plugged.eligible && plugged.changed, "battery-only timer is paused on power")
        let unplugged = gate.update(batteryOnly: true, sourceKnown: true, onAC: false)
        check(unplugged.eligible && unplugged.changed, "unplugging starts a fresh interval")
        check(!InactivitySleepPolicy.expired(minutes: 15, awake: true, idle: 10000, armedFor: 0), "pre-existing idle time does not shorten a freshly unplugged interval")
        check(!gate.update(batteryOnly: true, sourceKnown: true, onAC: false).changed, "remaining on battery does not reset the interval")
        let replugged = gate.update(batteryOnly: true, sourceKnown: true, onAC: true)
        check(!replugged.eligible && replugged.changed, "connecting power suspends a pending timer")
        check(!gate.update(batteryOnly: true, sourceKnown: false, onAC: false).eligible, "unknown power source cannot trigger battery-only sleep")
        check(gate.update(batteryOnly: false, sourceKnown: true, onAC: true).eligible, "ordinary timer remains available on power")
        check(!InactivitySleepPolicy.expired(minutes: 0, awake: true, idle: 10000, armedFor: 10000), "timer off does nothing")
        check(!InactivitySleepPolicy.expired(minutes: 15, awake: false, idle: 1000, armedFor: 1000), "timer does not turn off an inactive app")
        check(!InactivitySleepPolicy.expired(minutes: 15, awake: true, idle: 1000, armedFor: 5), "enabling starts a fresh inactivity interval")
        check(!InactivitySleepPolicy.expired(minutes: 15, awake: true, idle: .nan, armedFor: 1000), "unknown input activity never triggers sleep")
        check(!InactivitySleepPolicy.expired(minutes: 15, awake: true, idle: 899, armedFor: 1000), "timer waits for the full idle interval")
        check(InactivitySleepPolicy.expired(minutes: 15, awake: true, idle: 900, armedFor: 900), "timer expires after continuous inactivity")
        check(InactivitySleepPolicy.shouldRestart(minutes: 15, pending: true, idle: 1), "activity during pending sleep restarts the timer")
        check(!InactivitySleepPolicy.shouldRestart(minutes: 15, pending: false, idle: 1), "activity cannot undo manual Off")
        check(!InactivitySleepPolicy.shouldRestart(minutes: 0, pending: true, idle: 1), "disabled timer cannot resume keep-awake")
        check(!InactivitySleepPolicy.shouldRestart(minutes: 15, pending: true, idle: .nan), "unreadable activity cannot resume keep-awake")
        check(!InactivitySleepPolicy.expired(minutes: 15, awake: true, idle: 1, armedFor: 1000), "activity restarts a running countdown")
        check(!InactivitySleepPolicy.shouldRetry(minutes: 15, pending: true, idle: 900, sleepDisabled: nil, now: 1000, lastAttempt: nil), "unverified sleep setting prevents sleep request")
        check(!InactivitySleepPolicy.shouldRetry(minutes: 15, pending: true, idle: 1, sleepDisabled: false, now: 1000, lastAttempt: nil), "returning user cancels sleep request")
        check(InactivitySleepPolicy.shouldRetry(minutes: 15, pending: true, idle: 900, sleepDisabled: false, now: 1000, lastAttempt: nil), "normal sleep restored and idle permits request")
        check(!InactivitySleepPolicy.shouldRetry(minutes: 15, pending: true, idle: 900, sleepDisabled: false, now: 1029, lastAttempt: 1000), "failed sleep request is rate limited")
        check(InactivitySleepPolicy.shouldRetry(minutes: 15, pending: true, idle: 900, sleepDisabled: false, now: 1030, lastAttempt: 1000), "unobserved sleep request can retry")
    }

    private static func hotspotPolicyTests() {
        print("== Hotspot fallback policy")
        let older = HotspotProfile(name: "Old", lastConnected: Date(timeIntervalSince1970: 1), personal: true)
        let newer = HotspotProfile(name: "New", lastConnected: Date(timeIntervalSince1970: 2), personal: true)
        let wifi = HotspotProfile(name: "Wi-Fi", lastConnected: Date(timeIntervalSince1970: 3), personal: false)
        check(HotspotProfile.mostRecent(in: [older, newer, wifi])?.name == "New", "select most recently connected personal hotspot")
        check(HotspotProfile.mostRecent(in: [wifi]) == nil, "never choose an ordinary Wi-Fi network")
        var timing = HotspotProbeTiming()
        check(timing.shouldStart(now: 0), "first internet probe starts immediately")
        check(!timing.shouldStart(now: 9.9), "coalesced timer cannot start a probe too early")
        check(timing.shouldStart(now: 10), "probe starts after ten seconds")
        timing.reset()
        check(timing.shouldStart(now: 11), "stopping resets probe timing")
        check(!HotspotDisconnectPolicy.shouldPause(tracked: nil, current: nil, locationAuthorized: true), "untracked Wi-Fi changes do not pause fallback")
        check(!HotspotDisconnectPolicy.shouldPause(tracked: "test", current: "test", locationAuthorized: true), "same hotspot does not pause fallback")
        check(HotspotDisconnectPolicy.shouldPause(tracked: "test", current: nil, locationAuthorized: true), "disconnect pauses fallback with unknown cause")
        check(HotspotDisconnectPolicy.shouldPause(tracked: "test", current: "other", locationAuthorized: true), "switching networks pauses fallback")
        check(!HotspotDisconnectPolicy.shouldPause(tracked: "test", current: nil, locationAuthorized: false), "missing location access is not treated as disconnect")
        var policy = HotspotRetryPolicy()
        check(!policy.observe(online: false, now: 0), "one failed check cannot switch networks")
        check(!policy.observe(online: true, now: 10), "working internet resets failure count")
        check(!policy.observe(online: false, now: 20), "new failures start a fresh count")
        check(policy.observe(online: false, now: 30), "two failed checks permit one attempt")
        check(!policy.observe(online: false, now: 40) && !policy.observe(online: false, now: 50)
              && !policy.observe(online: false, now: 320), "retries are rate limited")
        check(policy.observe(online: false, now: 330), "retry allowed after cooldown")
        policy.reset()
        check(!policy.observe(online: false, now: 331), "disabling resets the policy")
        let fake = FakeHotspotSession()
        var result: (name: String, password: String)?
        let discovery = HotspotDiscovery(name: "Recent phone", sessionFactory: { fake }) { result = $0 }
        discovery.start()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        check(fake.requestedName == "Recent phone" && result?.name == "Recent phone" && result?.password == "test-only",
              "discovery selects matching device and handles private-API callback")
        let fallback = FakeHotspotSession(); fallback.failFirst = true
        var fallbackResult: (name: String, password: String)?
        let fallbackDiscovery = HotspotDiscovery(name: "Recent phone", sessionFactory: { fallback }) { fallbackResult = $0 }
        fallbackDiscovery.start()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        check(fallback.usedFallback && fallbackResult?.name == "Recent phone", "alternate private selector handles a failed first request")
    }

    private static func assertionTests() {
        print("== Assertion error handling")
        var attempts = 0
        var released: UInt32 = 0
        let assertion = SleepAssertion(create: { id in
            attempts += 1
            if attempts == 1 { return -1 }
            id = 42
            return 0
        }, release: { id in released = id; return 0 })
        check(assertion.hold() == -1 && !assertion.isHeld, "failed assertion is reported")
        check(assertion.hold() == nil && assertion.isHeld, "failed assertion is retried")
        check(assertion.hold() == nil && attempts == 2, "held assertion is not recreated")
        assertion.release()
        check(!assertion.isHeld && released == 42, "acquired assertion is released")
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
        var clicks = IconClickSequence()
        clicks.receive(clickCount: 1, at: 10, interval: 0.5)
        check(clicks.resolve(at: 10.4) == nil, "single click waits for system interval")
        check(clicks.resolve(at: 10.52) == .menu, "single click opens menu after interval")
        clicks.receive(clickCount: 1, at: 20, interval: 0.5)
        clicks.receive(clickCount: 2, at: 20.2, interval: 0.5)
        check(clicks.resolve(at: 20.72) == .toggle, "double click toggles once")
        clicks.receive(clickCount: 3, at: 30, interval: 0.5)
        check(clicks.resolve(at: 30.52) == .ignore, "triple click does not toggle")
        clicks.receive(clickCount: 1, at: 40, interval: 0.5)
        clicks.cancel()
        check(clicks.resolve(at: 41) == nil, "secondary click cancels pending primary click")
        let legacyConfig = Data(#"{"wantAwake":true,"allowOnBattery":true,"minBatteryPercent":10,"virtualDisplay":true,"startAtLogin":true}"#.utf8)
        check((try? JSONDecoder().decode(KeepAwakeConfiguration.self, from: legacyConfig)) != nil,
              "legacy running-app state decodes before guarded upgrade")
        check(CLI.validSetting("doubleClickToToggle=1") && !CLI.validSetting("doubleClickToToggle=2"), "gesture CLI setting validated")
    }

    private static func hotspotRetentionTests() {
        print("== Hotspot diagnostics retention")
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("caffeine-hotspot-test-" + UUID().uuidString)
        defer { try? fm.removeItem(at: dir) }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let now = Date(timeIntervalSince1970: 2_000_001_800)
            let cutoff = now.timeIntervalSince1970 - 30 * 24 * 3600
            let hour = Int(cutoff) / 3600
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            func row(_ seconds: Double) -> String { "{\"t\":\"\(formatter.string(from: Date(timeIntervalSince1970: seconds)))\"}\n" }
            let boundary = dir.appendingPathComponent("events-\(hour).jsonl")
            let old = dir.appendingPathComponent("events-\(hour-1).jsonl")
            try row(cutoff - 1).write(to: old, atomically: true, encoding: .utf8)
            try (row(cutoff - 1) + row(cutoff + 1)).write(to: boundary, atomically: true, encoding: .utf8)
            HotspotDiagnosticLog.prune(now: now, directory: dir)
            check(!fm.fileExists(atPath: old.path), "old hotspot log is removed")
            check(try String(contentsOf: boundary, encoding: .utf8) == row(cutoff + 1), "boundary keeps only 30-day hotspot records")
        } catch { check(false, "hotspot retention test setup") }
    }

    private static func performanceRetentionTests() {
        hotspotRetentionTests()
        print("== Performance retention")
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("caffeine-perf-test-" + UUID().uuidString)
        defer { try? fm.removeItem(at: directory) }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let now = Date(timeIntervalSince1970: 2_000_001_800)
            let cutoff = Int(now.timeIntervalSince1970) - 30 * 24 * 3600
            let hour = cutoff / 3600
            let old = directory.appendingPathComponent("sample-\(hour - 1).csv")
            let boundary = directory.appendingPathComponent("sample-\(hour).csv")
            let unrelated = directory.appendingPathComponent("other.csv")
            try "old".write(to: old, atomically: true, encoding: .utf8)
            try "\(cutoff - 1),1.0,nominal\n\(cutoff),2.0,fair\n".write(to: boundary, atomically: true, encoding: .utf8)
            try "leave me".write(to: unrelated, atomically: true, encoding: .utf8)
            PerformanceLog.prune(now: now, directory: directory)
            let remaining = try String(contentsOf: boundary, encoding: .utf8)
            check(!fm.fileExists(atPath: old.path), "expired hour removed")
            check(remaining == "\(cutoff),2.0,fair\n", "boundary retains only samples within 30 days")
            check(fm.fileExists(atPath: unrelated.path), "retention leaves unrelated files untouched")
            let sample = directory.appendingPathComponent("sample-baseline.csv")
            let origin = Int(now.timeIntervalSince1970) - 3600
            let good = (0...30).map { "\(origin + $0 * 60),10,nominal,50.0,1" }
            let bad = (0...50).map { "\(origin + $0 * 60),10,nominal,100.0,0" }
            try (good + bad).joined(separator: "\n").write(to: sample, atomically: true, encoding: .utf8)
            let range = PerformanceLog.typicalRange(now: now, directory: directory)
            check(range?.0 == 50 && range?.1 == 50, "baseline excludes closed or inactive samples")

        } catch { check(false, "performance retention test: \(error)") }
    }

    private static func sleepOwnershipTests() {
        print("== Sleep override ownership")
        check(SleepOwnership.decision(want: false, actual: true, owned: false) == .noChange, "off preserves external sleep override")
        check(SleepOwnership.decision(want: true, actual: true, owned: false) == .keepExternal, "existing override is not claimed")
        check(SleepOwnership.decision(want: true, actual: false, owned: false) == .acquire, "claim before enabling own override")
        check(SleepOwnership.decision(want: false, actual: true, owned: true) == .release, "release our override")
        check(SleepOwnership.decision(want: false, actual: false, owned: true) == .clearRecord, "clear recovered ownership after already restored")
        check(SleepOwnership.decision(want: false, actual: nil, owned: true) == .unavailable, "never mutate unreadable system state")
        check(SleepOwnership.decision(want: true, actual: true, owned: true) == .keepOwned, "preserve ownership across process restart")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("caffeine-owner-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            let marker = temp.appendingPathComponent("owner")
            try SleepOwnership.claim(boot: "123", record: marker)
            check(SleepOwnership.isOwned(boot: "123", record: marker), "ownership persists to disk")
            check(SleepOwnership.isOwned(boot: "124", record: marker), "prior boot ownership carries across reboot")
            check(!SleepOwnership.isOwned(boot: "122", record: marker), "future ownership record is rejected")
            try "invalid".write(to: marker, atomically: true, encoding: .utf8)
            check(!SleepOwnership.isOwned(boot: "124", record: marker), "invalid ownership record is rejected")
            try SleepOwnership.clear(record: marker)
            check(!SleepOwnership.isOwned(boot: "123", record: marker), "ownership clears after release")
        } catch { check(false, "ownership record test: \(error)") }

    }

    private static func thermalSafetyTests() {
        print("== Thermal safety")
        var thermal = ThermalStopPolicy()
        check(thermal.evaluate(thermal: "serious", enabled: false, now: 0) == nil, "serious pressure is configurable")
        check(thermal.evaluate(thermal: "serious", enabled: true, now: 10) == nil, "brief serious pressure does not stop keep-awake")
        check(thermal.evaluate(thermal: "serious", enabled: true, now: 69) == nil, "serious pressure must persist for 60 seconds")
        check(thermal.evaluate(thermal: "serious", enabled: true, now: 70) != nil, "sustained serious pressure stops keep-awake")
        check(thermal.evaluate(thermal: "fair", enabled: true, now: 71) == nil, "cooling resets sustained pressure timer")
        check(thermal.evaluate(thermal: "serious", enabled: true, now: 72) == nil, "serious timer starts again after cooling")
        check(thermal.evaluate(thermal: "critical", enabled: false, now: 73) != nil, "critical pressure always stops immediately")
        var retry = SleepRetryPolicy()
        check(!retry.shouldRequest(pending: true, lidClosed: nil, normalSleepConfirmed: true, now: 0), "unknown lid never forces sleep")
        check(!retry.shouldRequest(pending: true, lidClosed: true, normalSleepConfirmed: false, now: 0), "wait for normal sleep setting before requesting sleep")
        check(retry.shouldRequest(pending: true, lidClosed: true, normalSleepConfirmed: true, now: 1), "request sleep after normal sleep is confirmed")
        check(!retry.shouldRequest(pending: true, lidClosed: true, normalSleepConfirmed: true, now: 30), "failed or unobserved sleep is rate limited")
        check(retry.shouldRequest(pending: true, lidClosed: true, normalSleepConfirmed: true, now: 31), "retry unobserved sleep after 30 seconds")
        check(!retry.shouldRequest(pending: false, lidClosed: true, normalSleepConfirmed: true, now: 90), "stop retrying after recovery")
        check(CLI.validSetting("stopOnSeriousThermal=1") && !CLI.validSetting("stopOnSeriousThermal=2"), "serious heat setting accepts only boolean values")
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
