import AppKit
import CoreLocation

struct MenuRow {
    enum Kind {
        case headline, section, info, warning, action, separator
        case toggle(Bool)
        case submenu([MenuRow])
    }

    var title: String
    var kind: Kind
    var symbol: String? = nil
    var action: Selector? = nil
    var key: String = ""
    var value: String? = nil
    var tooltip: String? = nil

    static let separator = MenuRow(title: "—", kind: .separator)

    /// Plain-text rendering, published in state.json so the menu can be checked without a screenshot.
    var flatTitles: [String] {
        switch kind {
        case .separator: return ["—"]
        case .toggle(let on): return ["[\(on ? "x" : " ")] \(title)"]
        case .warning: return ["! \(title)"]
        case .submenu(let children): return ["\(title) ▸"] + children.flatMap { $0.flatTitles.map { "    " + $0 } }
        default: return [title]
        }
    }
}

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let command = Notification.Name("local.caffeine.command")

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let assertion = SleepAssertion()
    private let virtualDisplay = VirtualDisplay()
    private let hotspot = HotspotMonitor()
    private lazy var hotspotLocation = CLLocationManager()
    private lazy var capsSwitch = CapsLockSwitch(desired: { (Prefs.wantAwake, Prefs.idleSleepMinutes > 0) },
                                                  change: { [weak self] in self?.setWantAwake($0) },
                                                  report: { [weak self] problem in self?.capsProblem = problem })
    private let tracker = LidTracker()
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var signalSource: DispatchSourceSignal?
    private var tickCount = 0
    private var lastTick = Date()
    private var lastTickUptime = ProcessInfo.processInfo.systemUptime
    private var observedLidClosed: Bool?
    private var sleepObservation: Pmset.SleepObservation?
    private var lastLoggedContext: DiagnosticContext?
    private var screensAsleep: Bool?
    private var sessionActive: Bool?
    private var screenLocked: Bool?
    private var systemSleepAt: Date?
    private var systemSleepID: String?
    private var currentIcon = ""
    private var clickTimer: Timer?
    private var clicks = IconClickSequence()

    private let debug = ProcessInfo.processInfo.environment["CAFFEINE_DEBUG"] == "1"
    private var simulation: [String: String] = [:]
    private var simulatedVirtualDisplay = false
    private var virtualDisplayFailedAt = Date.distantPast
    private var virtualDisplayEligibleSince: Date?
    private var displayReconcileScheduled = false
    private var virtualDisplayCreatedUptime: TimeInterval?
    private var virtualDisplaySuspensionReason: String?
    private var handingOff = false
    private var lastCommandID: String?

    private var refreshInFlight = false
    private var pendingRefreshIDs: [String] = []
    private var sensorsKnown = true
    private var snapshot: Snapshot?
    private var lastApply = Date.distantPast
    private var lidClosed = false
    private var power = PowerState(onAC: true)
    private var thermal = "nominal"
    private var sleepDisabled = false
    private var decision: GuardDecision = .allow
    private var permissionProblem: String?
    private var assertionFailure: IOReturn?
    private var capsProblem: String?
    private var thermalPolicy = ThermalStopPolicy()
    private var sleepRetry = SleepRetryPolicy()
    private var sleepRequestProblem: String?
    private var idleArmedAt = ProcessInfo.processInfo.systemUptime
    private var lastIdleSleepAttempt: TimeInterval?
    private var unexpectedSleepAt: Date?
    private var lidPausedReason: String?
    private var lastResult = Prefs.lastResult

    private var isActive: Bool { Prefs.wantAwake && decision == .allow && sleepDisabled }

    private var headline: String {
        if !Prefs.wantAwake {
            if let reason = Prefs.thermalStopReason { return "Off: \(reason)" }
            return "Off: follows macOS sleep settings"
        }
        if let reason = decision.reason { return "Paused: \(reason)" }
        if !sleepDisabled { return "Not active: can't change the sleep setting" }
        if !power.onAC && !Prefs.allowOnBattery { return "On, but on battery: closing the lid will sleep" }
        return "On: stays awake with the lid closed"
    }

    /// Why Caffeine isn't holding the Mac awake right now (nil while it is).
    private var pauseReason: String? {
        if isActive { return nil }
        if !Prefs.wantAwake { return "keep-awake was off" }
        return decision.reason ?? permissionProblem ?? "sleep setting not applied"
    }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.migrateVirtualDisplayPreference()
        if Prefs.autoHotspot { hotspot.start() }
        if Prefs.capsLockSwitch { capsSwitch.start() }
        // Keep timers on schedule (no App Nap) without holding the system awake by itself.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "Caffeine watches lid and power state")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.button?.target = self
        statusItem.button?.action = #selector(iconClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        DistributedNotificationCenter.default().addObserver(self, selector: #selector(handleCommand(_:)),
                                                            name: Self.command, object: nil,
                                                            suspensionBehavior: .deliverImmediately)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sessionBecameActive), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sessionBecameInactive), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(displayConfigurationChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Best-effort distributed lock notifications. Session activation alone does not mean a lock/unlock.
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(screenDidLock), name: Notification.Name("com.apple.screenIsLocked"),
                                object: nil, suspensionBehavior: .deliverImmediately)
        distributed.addObserver(self, selector: #selector(screenDidUnlock), name: Notification.Name("com.apple.screenIsUnlocked"),
                                object: nil, suspensionBehavior: .deliverImmediately)

        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        signalSource = source

        sleepObservation = Pmset.observeSleepDisabled()
        sleepDisabled = sleepObservation?.value ?? false
        readFastSensors()
        var launch = EventLog.identity
        launch["byLoginItem"] = LoginItem.launchedByAgent
        launch["debug"] = debug
        log("launch", launch)
        PerformanceLog.prime()
        tick()
        refresh()
        let timer = Timer(timeInterval: 5, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotspot.stop()
        if Prefs.capsLockSwitch { capsSwitch.stop() }
        virtualDisplay.destroy()
        assertion.release()
        if handingOff {
            log("quit", ["handoff": true])
            EventLog.flush()
            return
        }
        // Caffeine only keeps SleepDisabled set while it's running with its guards active.
        let restoreRequested = sleepDisabled
        if restoreRequested { lastApply = .distantPast; apply(false) }
        sleepObservation = Pmset.observeSleepDisabled()
        sleepDisabled = sleepObservation?.value ?? sleepDisabled
        log("quit", ["sleepRestoreRequested": restoreRequested,
                     "normalSleepObserved": sleepObservation?.value == false])
        EventLog.flush()
    }

    // MARK: Loop

    @objc private func tick() {
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let previousTick = lastTick
        let gap = TickGap(wallSeconds: now.timeIntervalSince(lastTick), uptimeSeconds: uptime - lastTickUptime)
        lastTick = now
        lastTickUptime = uptime

        readFastSensors()
        reconcile()
        enforceInactivitySleep()
        recordTransitions()
        if gap.shouldLog {
            log("scheduling_gap", gap.fields)
            collectPowerEvidence(trigger: "scheduling_gap", from: min(previousTick, now).addingTimeInterval(-5),
                                 to: max(previousTick, now).addingTimeInterval(5), correlationID: UUID().uuidString)
        }
        switch tracker.beat(now: now, lidClosed: lidClosed, active: isActive) {
        case .closed:
            lidPausedReason = pauseReason
            log("lid_closed", ["active": isActive, "onAC": power.onAC, "pausedReason": lidPausedReason ?? ""])
        case .opened(let session):
            finish(session, pausedReason: lidPausedReason)
            lidPausedReason = nil
        case .none:
            // E.g. unplugged while the lid was already shut: the guard's sleep is expected, not a failure.
            if lidClosed && lidPausedReason == nil { lidPausedReason = pauseReason }
        }
        tickCount += 1
        if tickCount % 12 == 0 {
            let idle = CaffeineSecondsSinceInput()
            let activeOpen = observedLidClosed == false && idle < 300 && screenLocked != true && screensAsleep != true
            PerformanceLog.sample(thermal: thermal, activeWithLidOpen: activeOpen)
            if lidClosed { heartbeat() }
        }
        if tickCount % 6 == 0 { refresh() }
        updateIcon()
    }

    private func enforceInactivitySleep() {
        let minutes = Prefs.idleSleepMinutes
        let now = ProcessInfo.processInfo.systemUptime
        let idle = CaffeineSecondsSinceInput()
        if InactivitySleepPolicy.expired(minutes: minutes, awake: Prefs.wantAwake, idle: idle, armedFor: now - idleArmedAt) {
            Prefs.wantAwake = false
            Prefs.idleSleepPending = true
            Prefs.persistSafetyState()
            lastApply = .distantPast
            log("idle_keep_awake_disabled", ["idleMinutes": minutes])
            reconcile()
        }
        guard Prefs.idleSleepPending else { lastIdleSleepAttempt = nil; return }
        if InactivitySleepPolicy.shouldRestart(minutes: minutes, pending: true, idle: idle) {
            // Resume only the session stopped by this timer. Manual Off clears pending.
            Prefs.idleSleepPending = false
            setWantAwake(true)
            Prefs.persistSafetyState()
            log("idle_timer_restarted", ["minutes": minutes, "resumed": Prefs.wantAwake])
            return
        }
        if minutes == 0 {
            Prefs.idleSleepPending = false
            Prefs.persistSafetyState()
            lastIdleSleepAttempt = nil
            sleepRequestProblem = nil
            log("idle_sleep_cancelled", ["reason": "timer disabled"])
            return
        }
        sleepObservation = Pmset.observeSleepDisabled()
        if sleepObservation?.value != false { apply(false) }
        // Activity during the system-setting check also starts a fresh interval.
        let currentIdle = CaffeineSecondsSinceInput()
        if InactivitySleepPolicy.shouldRestart(minutes: minutes, pending: true, idle: currentIdle) {
            Prefs.idleSleepPending = false
            setWantAwake(true)
            Prefs.persistSafetyState()
            log("idle_timer_restarted", ["minutes": minutes, "resumed": Prefs.wantAwake])
            return
        }
        if InactivitySleepPolicy.shouldRetry(minutes: minutes, pending: Prefs.idleSleepPending, idle: currentIdle,
                                             sleepDisabled: sleepObservation?.value, now: now, lastAttempt: lastIdleSleepAttempt) {
            lastIdleSleepAttempt = now
            if simulation.isEmpty {
                let accepted = Pmset.sleepNow()
                sleepRequestProblem = accepted ? "Idle sleep requested; retrying if needed" : "Idle sleep request failed; retrying"
                log("idle_sleep_requested", ["accepted": accepted])
            } else { log("idle_sleep_requested", ["simulated": true]) }
        }
    }

    private func readFastSensors() {
        let sensedLid = Sensors.lidClosed()
        observedLidClosed = simulation["lid"].map { $0 == "closed" } ?? sensedLid
        lidClosed = simulation["lid"].map { $0 == "closed" } ?? sensedLid ?? lidClosed
        var p = Sensors.power()
        if let ac = simulation["ac"] { p.onAC = ac == "1" }
        if let battery = simulation["battery"].flatMap(Int.init) { p.batteryPercent = battery }
        power = p
        sensorsKnown = !simulation.isEmpty || (sensedLid != nil && p.sourceKnown != false)
        thermal = simulation["thermal"] ?? Sensors.thermal()
    }

    private func reconcile() {
        let thermalReason = thermalPolicy.evaluate(thermal: thermal, enabled: Prefs.stopOnSeriousThermal,
                                                   now: ProcessInfo.processInfo.systemUptime)
        if Prefs.wantAwake, let reason = thermalReason {
            Prefs.thermalStopReason = reason
            Prefs.thermalStopPending = true
            Prefs.wantAwake = false
            Prefs.persistSafetyState()
            lastApply = .distantPast
            log("thermal_keep_awake_disabled", ["reason": reason])
        }
        let want = Prefs.wantAwake
        let input = GuardInput(lidClosed: lidClosed, onAC: power.onAC, batteryPercent: power.batteryPercent,
                               thermal: thermal, allowOnBattery: Prefs.allowOnBattery,
                               minBatteryPercent: Prefs.minBatteryPercent, sensorsKnown: sensorsKnown)
        let newDecision = want ? Guards.evaluate(input) : .allow
        if newDecision != decision {
            decision = newDecision
            if let reason = newDecision.reason {
                log("guard_tripped", ["reason": reason, "lidClosed": lidClosed])
            } else {
                log("guard_cleared")
            }
        }

        let shouldDisableSleep = want && newDecision == .allow
        if shouldDisableSleep != sleepDisabled || (!shouldDisableSleep && SleepOwnership.bootID().map({ SleepOwnership.isOwned(boot: $0) }) == true) { apply(shouldDisableSleep) }
        if shouldDisableSleep {
            let failure = assertion.hold()
            if failure != assertionFailure {
                if let failure { log("assertion_failed", ["code": failure]) }
                else if assertionFailure != nil { log("assertion_restored") }
                assertionFailure = failure
            }
        } else {
            assertion.release()
            assertionFailure = nil
        }
        updateVirtualDisplay()

        let recoveryNeeded = Prefs.thermalStopPending || (want && newDecision != .allow)
        if recoveryNeeded {
            // Re-read the actual kernel setting: after a crash our cached state can be stale.
            sleepObservation = Pmset.observeSleepDisabled()
            if sleepObservation?.value != false { apply(false) }
            if Prefs.thermalStopPending, observedLidClosed == false, sleepObservation?.value == false {
                Prefs.thermalStopPending = false
                Prefs.persistSafetyState()
                sleepRetry.reset()
                sleepRequestProblem = nil
                log("thermal_recovery_complete", ["reason": "lid open; normal sleep restored"])
            } else if sleepRetry.shouldRequest(pending: true, lidClosed: observedLidClosed,
                                                normalSleepConfirmed: sleepObservation?.value == false,
                                                now: ProcessInfo.processInfo.systemUptime) {
                let reason = Prefs.thermalStopReason ?? newDecision.reason ?? "Safety guard"
                if simulation.isEmpty {
                    let accepted = Pmset.sleepNow()
                    sleepRequestProblem = accepted ? "Sleep not yet observed; retrying if needed" : "Sleep request failed; retrying"
                    log("sleep_now", ["reason": reason, "accepted": accepted, "retrySeconds": 30])
                } else { log("sleep_now", ["reason": reason, "simulated": true]) }
            }
        } else { sleepRetry.reset(); if !Prefs.idleSleepPending { sleepRequestProblem = nil } }
    }

    private func apply(_ disable: Bool) {
        if permissionProblem != nil && Date().timeIntervalSince(lastApply) < 30 { return }
        lastApply = Date()
        let previousProblem = permissionProblem
        do {
            try SleepOwnership.withLock {
                guard let boot = SleepOwnership.bootID() else { throw NSError(domain: "Caffeine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot identify the current boot"]) }
                let observed = Pmset.observeSleepDisabled()
                sleepObservation = observed
                guard let actual = observed.value else { throw NSError(domain: "Caffeine", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot read system sleep setting"]) }
                sleepDisabled = actual
                let owned = SleepOwnership.isOwned(boot: boot)
                switch SleepOwnership.decision(want: disable, actual: actual, owned: owned) {
                case .keepExternal, .noChange:
                    // Another actor may own the global setting; don't take credit or reset it.
                    permissionProblem = !disable && actual ? "Sleep is disabled externally; Caffeine did not change it" : nil
                case .keepOwned: permissionProblem = nil
                case .clearRecord:
                    try SleepOwnership.clear(); permissionProblem = nil
                case .acquire, .release:
                    if disable { try SleepOwnership.claim(boot: boot) } // durable before the privileged change
                    let result = Pmset.setSleepDisabled(disable)
                    sleepObservation = Pmset.observeSleepDisabled()
                    sleepDisabled = sleepObservation?.value ?? actual
                    if sleepObservation?.value == disable {
                        if !disable { try SleepOwnership.clear() }
                        permissionProblem = nil
                        log(disable ? "sleep_disabled" : "sleep_restored")
                    } else {
                        if disable && sleepObservation?.value == false { try? SleepOwnership.clear() }
                        switch result {
                        case .failure(.needsPermission): permissionProblem = "Permission rule not installed"
                        case .failure(.failed(let message)): permissionProblem = message
                        case .success: permissionProblem = "Sleep setting could not be verified"
                        }
                    }
                case .unavailable: permissionProblem = "Cannot read system sleep setting"
                }
            }
        } catch { permissionProblem = "Sleep ownership unavailable: \(error.localizedDescription)" }
        if let problem = permissionProblem, problem != previousProblem {
            log("apply_failed", ["reason": problem, "wanted": disable])
        }
    }

    private func updateVirtualDisplay() {
        let eligibility = VirtualDisplayPolicy.evaluate(enabled: Prefs.virtualDisplay, protectionActive: isActive,
                                                        lidClosed: observedLidClosed, displays: Sensors.displays())
        if [.lidOpen, .disabled, .protectionInactive].contains(eligibility) {
            virtualDisplaySuspensionReason = nil
        }
        guard simulation.isEmpty else {
            if eligibility.shouldExist != simulatedVirtualDisplay {
                simulatedVirtualDisplay = eligibility.shouldExist
                log(simulatedVirtualDisplay ? "virtual_display_on" : "virtual_display_off",
                    ["simulated": true, "reason": eligibility.rawValue])
            }
            return
        }
        guard eligibility.shouldExist else {
            virtualDisplayEligibleSince = nil
            if virtualDisplay.isActive {
                let age = virtualDisplayCreatedUptime.map { ProcessInfo.processInfo.systemUptime - $0 }
                if VirtualDisplayPolicy.shouldPauseForSession(eligibility: eligibility, secondsSinceCreation: age) {
                    virtualDisplaySuspensionReason = "Real display reactivated during headless setup; retry after opening the lid"
                    log("virtual_display_suspended", ["reason": virtualDisplaySuspensionReason!])
                }
                virtualDisplay.destroy()
                virtualDisplayCreatedUptime = nil
                log("virtual_display_off", ["reason": eligibility.rawValue])
            }
            return
        }
        guard virtualDisplaySuspensionReason == nil, !virtualDisplay.isActive else { return }
        let now = Date()
        if virtualDisplayEligibleSince == nil {
            virtualDisplayEligibleSince = now
            // Let lid/hotplug configuration settle; recheck live sensors before creating anything.
            DispatchQueue.main.asyncAfter(deadline: .now() + VirtualDisplayPolicy.settleSeconds) { [weak self] in
                guard let self else { return }
                self.readFastSensors()
                self.reconcile()
                self.writeState()
            }
            return
        }
        guard now.timeIntervalSince(virtualDisplayEligibleSince!) >= VirtualDisplayPolicy.settleSeconds,
              now.timeIntervalSince(virtualDisplayFailedAt) > 60 else { return }
        if virtualDisplay.create() {
            virtualDisplayCreatedUptime = ProcessInfo.processInfo.systemUptime
            log("virtual_display_on", ["reason": eligibility.rawValue])
        } else {
            virtualDisplayFailedAt = now
            log("virtual_display_failed", ["reason": eligibility.rawValue])
        }
    }

    @objc private func displayConfigurationChanged() {
        guard !displayReconcileScheduled else { return }
        displayReconcileScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.displayReconcileScheduled = false
            self.readFastSensors()
            self.updateVirtualDisplay()
            self.writeState()
        }
    }

    private func heartbeat() {
        let displays = Sensors.displays()
        log("heartbeat", ["lidClosed": lidClosed, "active": isActive, "onAC": power.onAC,
                                     "battery": power.batteryPercent ?? -1, "thermal": thermal,
                                     "displays": displays.active, "virtualDisplay": displays.virtualActive])
    }

    private func finish(_ session: LidTracker.Session, pausedReason: String?) {
        let seconds = Int(session.openedAt.timeIntervalSince(session.closedAt))
        let correlationID = UUID().uuidString
        let context = diagnosticContext()
        log("lid_opened", ["closedSeconds": seconds, "maxGapSeconds": Int(session.maxGap), "correlationID": correlationID])
        guard seconds >= 30 else { return }
        // Wait past the five-second evidence window for powerd to flush records; never block the UI.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 6) {
            let evidence = Pmset.evidence(from: session.closedAt.addingTimeInterval(-10), to: session.openedAt.addingTimeInterval(5))
            DispatchQueue.main.async { [self] in
                let result = LidSessionResult(closedAt: session.closedAt, openedAt: session.openedAt,
                                              maxGapSeconds: Int(session.maxGap), sleepEvents: evidence.systemSleepCount,
                                              activeThroughout: session.activeThroughout, pausedReason: pausedReason,
                                              sleepLogAvailable: evidence.error == nil)
                record(result)
                recordPowerEvidence(evidence, trigger: "lid_session", from: session.closedAt.addingTimeInterval(-10),
                                    to: session.openedAt.addingTimeInterval(5), correlationID: correlationID, context: context)
            }
        }
    }

    private func record(_ result: LidSessionResult) {
        lastResult = result
        Prefs.lastResult = result
        log("lid_session", ["minutes": result.minutes, "maxGapSeconds": result.maxGapSeconds,
                                       "sleepEvents": result.sleepEvents, "stayedAwake": result.stayedAwake,
                                       "activeThroughout": result.activeThroughout, "failed": result.failed,
                                       "pausedReason": result.pausedReason ?? ""])
        writeState()
    }

    @objc private func willSleep() {
        readFastSensors()
        systemSleepAt = Date()
        systemSleepID = UUID().uuidString
        log("system_will_sleep", ["correlationID": systemSleepID!, "notificationSource": "NSWorkspace"])
        if isActive { unexpectedSleepAt = systemSleepAt }
    }

    @objc private func didWake() {
        let now = Date()
        readFastSensors()
        if Prefs.idleSleepPending && systemSleepAt != nil {
            Prefs.idleSleepPending = false
            Prefs.persistSafetyState()
            lastIdleSleepAttempt = nil
            sleepRequestProblem = nil
            log("idle_sleep_complete")
        }
        if Prefs.thermalStopPending && systemSleepAt != nil {
            sleepObservation = Pmset.observeSleepDisabled()
            if sleepObservation?.value == false {
                Prefs.thermalStopPending = false
                Prefs.persistSafetyState()
                sleepRetry.reset()
                sleepRequestProblem = nil
                log("thermal_recovery_complete", ["reason": "system sleep and wake observed"])
            }
        }
        let correlationID = systemSleepID ?? UUID().uuidString
        log("system_did_wake", ["correlationID": correlationID, "notificationSource": "NSWorkspace",
                                "willSleepNotificationObserved": systemSleepAt != nil,
                                "wallSecondsSinceWillSleep": systemSleepAt.map { now.timeIntervalSince($0) } as Any? ?? NSNull()])
        collectPowerEvidence(trigger: "system_wake", from: (systemSleepAt ?? now.addingTimeInterval(-60)).addingTimeInterval(-10),
                             to: now.addingTimeInterval(5), correlationID: correlationID)
        if let sleptAt = unexpectedSleepAt, tracker.closedAt == nil {
            record(LidSessionResult(closedAt: sleptAt, openedAt: now, maxGapSeconds: Int(now.timeIntervalSince(sleptAt)),
                                    sleepEvents: 1, activeThroughout: true))
        }
        unexpectedSleepAt = nil
        systemSleepAt = nil
        systemSleepID = nil
        tick()
    }

    @objc private func screensDidSleep() {
        screensAsleep = true
        readFastSensors()
        log("screens_did_sleep", ["notificationSource": "NSWorkspace", "scope": "display_only"])
    }
    @objc private func screensDidWake() {
        screensAsleep = false
        readFastSensors()
        updateVirtualDisplay()
        log("screens_did_wake", ["notificationSource": "NSWorkspace", "scope": "display_only"])
        let now = Date()
        collectPowerEvidence(trigger: "screens_wake", from: now.addingTimeInterval(-30), to: now.addingTimeInterval(5),
                             correlationID: UUID().uuidString)
    }
    @objc private func sessionBecameActive() {
        sessionActive = true
        readFastSensors()
        updateVirtualDisplay()
        log("session_became_active", ["notificationSource": "NSWorkspace", "scope": "session_activity_not_lock_state"])
    }
    @objc private func sessionBecameInactive() {
        sessionActive = false
        readFastSensors()
        log("session_became_inactive", ["notificationSource": "NSWorkspace", "scope": "session_activity_not_lock_state"])
    }
    @objc private func screenDidLock() {
        screenLocked = true
        readFastSensors()
        log("screen_locked", ["notificationSource": "distributed_com.apple.screenIsLocked", "bestEffort": true])
    }
    @objc private func screenDidUnlock() {
        screenLocked = false
        readFastSensors()
        log("screen_unlocked", ["notificationSource": "distributed_com.apple.screenIsUnlocked", "bestEffort": true])
    }

    private func diagnosticContext() -> DiagnosticContext {
        DiagnosticContext(lidClosed: observedLidClosed, power: power, thermal: thermal, sensorsKnown: sensorsKnown,
                          configuration: .current, guardReason: decision.reason, cachedSleepDisabled: sleepDisabled,
                          sleepObservation: sleepObservation, assertionHeld: assertion.isHeld,
                          virtualDisplayOwned: virtualDisplay.isActive || simulatedVirtualDisplay,
                          displays: Sensors.displays(), screensAsleep: screensAsleep,
                          sessionActive: sessionActive, screenLocked: screenLocked,
                          virtualDisplaySuspension: virtualDisplaySuspensionReason)
    }
    private func log(_ event: String, _ fields: [String: Any] = [:]) {
        var values = fields
        values["context"] = diagnosticContext().fields
        EventLog.write(event, values)
    }
    private func recordTransitions() {
        let context = diagnosticContext()
        if let previous = lastLoggedContext {
            for event in context.changes(from: previous) { log(event, ["previousContext": previous.fields]) }
        }
        lastLoggedContext = context
    }
    private func collectPowerEvidence(trigger: String, from start: Date, to end: Date, correlationID: String) {
        let context = diagnosticContext()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 6) {
            let evidence = Pmset.evidence(from: start, to: end)
            DispatchQueue.main.async { [self] in
                recordPowerEvidence(evidence, trigger: trigger, from: start, to: end, correlationID: correlationID, context: context)
            }
        }
    }
    private func recordPowerEvidence(_ evidence: Pmset.Evidence, trigger: String, from start: Date, to end: Date,
                                     correlationID: String, context: DiagnosticContext) {
        var fields = evidence.fields
        let formatter = ISO8601DateFormatter()
        fields["trigger"] = trigger
        fields["correlationID"] = correlationID
        fields["rangeStart"] = formatter.string(from: start)
        fields["rangeEnd"] = formatter.string(from: end)
        fields["triggerContext"] = context.fields
        log("power_log_evidence", fields)
    }

    private func refresh(commandID: String? = nil) {
        if let commandID { pendingRefreshIDs.append(commandID) }
        guard !refreshInFlight else { return }
        refreshInFlight = true
        let started = Date()
        DispatchQueue.global(qos: .utility).async {
            let captured = Snapshot.capture()
            DispatchQueue.main.async { [self] in
                refreshInFlight = false
                snapshot = captured
                if lastApply < started { sleepDisabled = captured.sleepDisabled; sleepObservation = captured.sleepObservation }   // don't clobber a newer write
                reconcile()
                updateIcon()
                // Command acknowledgement follows completion of this refresh.
                if let last = pendingRefreshIDs.last { lastCommandID = last }
                pendingRefreshIDs.removeAll()
                writeState()
            }
        }
    }

    private func writeState() {
        recordTransitions()
        let context = diagnosticContext()
        let sim = simulation.isEmpty ? nil : simulation.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",")
        var state = AppState(time: Date(), pid: getpid(), headline: headline, wantAwake: Prefs.wantAwake,
                             active: isActive, sleepDisabled: sleepDisabled, assertionHeld: assertion.isHeld,
                             virtualDisplayActive: context.displays.virtualActive || simulatedVirtualDisplay,
                             guardReason: decision.reason, permissionProblem: permissionProblem,
                             lidClosed: lidClosed, onAC: power.onAC, batteryPercent: power.batteryPercent,
                             thermal: thermal, simulation: sim, lastResult: lastResult,
                             menu: rows().flatMap(\.flatTitles), snapshot: snapshot)
        state.lastCommandID = lastCommandID
        state.diagnostics = context
        state.virtualDisplayOwned = context.virtualDisplayOwned
        state.runID = EventLog.runID
        state.save()
    }

    private func updateIcon() {
        let name = !Prefs.wantAwake ? "cup.and.saucer" : (isActive ? "cup.and.saucer.fill" : "exclamationmark.triangle.fill")
        statusItem.button?.toolTip = "Caffeine: " + headline + (Prefs.doubleClickToToggle ? "\nDouble-click to toggle Keep Awake; single-click for menu." : "\nClick for menu.")
        guard name != currentIcon else { return }
        currentIcon = name
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Caffeine")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    // MARK: Menu

    private func info(_ title: String, _ symbol: String? = nil) -> MenuRow {
        MenuRow(title: title, kind: .info, symbol: symbol)
    }

    private func warning(_ title: String) -> MenuRow {
        MenuRow(title: title, kind: .warning, symbol: "exclamationmark.triangle")
    }

    private func rows() -> [MenuRow] {
        var rows: [MenuRow] = []
        let headSymbol = !Prefs.wantAwake ? "moon.zzz" : (isActive ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        rows.append(MenuRow(title: headline, kind: .headline, symbol: headSymbol))
        rows.append(MenuRow(title: "Keep Awake with Lid Closed", kind: .toggle(Prefs.wantAwake),
                            action: #selector(toggleAwake), key: "k"))
        if let problem = permissionProblem {
            rows.append(warning(problem))
            if problem == "Permission rule not installed" {
                rows.append(MenuRow(title: "Set Up Permission…", kind: .action, symbol: "key", action: #selector(showPermissionHelp)))
            }
        }
        if let failure = assertionFailure {
            rows.append(warning("Idle-sleep assertion unavailable (\(failure)); retrying"))
        }
        if let capsProblem { rows.append(warning(capsProblem)) }

        let temperatures = PerformanceLog.temperatureSummary()
        let cpuTemperature = temperatures.0.map { String(format: "CPU %.0f °C", $0) } ?? "CPU temp unavailable"
        rows.append(MenuRow(title: "\(Describe.power(power)) · \(Describe.thermal(thermal)) · \(cpuTemperature)",
                            kind: .info, symbol: "battery.100percent",
                            tooltip: "CPU temperature updates about once a minute and uses the hottest available core sensor."))
        if virtualDisplay.isActive {
            let observed = Sensors.displays()
            rows.append(MenuRow(title: "Virtual display: \(observed.virtualActive ? "active" : "idle")", kind: .info, symbol: "display",
                                tooltip: "This reflects the actual display state. macOS still controls display power and screen locking."))
        }
        rows.append(.separator)
        var cutoffs: [MenuRow] = [10, 15, 20, 30].map { percent in
            MenuRow(title: "\(percent)%", kind: .toggle(Prefs.minBatteryPercent == percent),
                    action: #selector(selectBatteryCutoff(_:)), value: String(percent))
        }
        cutoffs.append(.separator)
        cutoffs.append(MenuRow(title: "Custom…", kind: .action, action: #selector(customBatteryCutoff)))
        var idleChoices = [0, 15, 30, 60, 120].map { minutes in
            MenuRow(title: minutes == 0 ? "Off" : "\(minutes) minutes", kind: .toggle(Prefs.idleSleepMinutes == minutes),
                    action: #selector(selectIdleSleep(_:)), value: String(minutes))
        }
        idleChoices.append(MenuRow(title: "Custom…", kind: .action, action: #selector(customIdleSleep)))
        let restart = RestartSchedule.read()
        let restartChoices: [MenuRow] = [
            MenuRow(title: "Off", kind: .toggle(!restart.enabled), action: #selector(disableScheduledRestart)),
            MenuRow(title: "05:00 every day", kind: .toggle(restart.enabled && restart.hour == 5 && restart.minute == 0), action: #selector(defaultScheduledRestart)),
            MenuRow(title: "Custom Time…", kind: .action, action: #selector(customScheduledRestart))
        ]
        rows.append(MenuRow(title: "Options", kind: .submenu([
            MenuRow(title: "Allow on Battery (above \(Prefs.minBatteryPercent)%)", kind: .toggle(Prefs.allowOnBattery),
                    action: #selector(toggleAllowOnBattery)),
            MenuRow(title: "Battery Cutoff: \(Prefs.minBatteryPercent)%", kind: .submenu(cutoffs)),
            MenuRow(title: "Sleep After Inactivity: \(Prefs.idleSleepMinutes == 0 ? "Off" : "\(Prefs.idleSleepMinutes) min")", kind: .submenu(idleChoices),
                    tooltip: "Turns Keep Awake off and requests sleep after no keyboard or mouse activity."),
            MenuRow(title: "Daily Forced Restart: \(restart.label)", kind: .submenu(restartChoices),
                    tooltip: "Forces a restart at the chosen local time, including before login. Unsaved work will be lost."),
            MenuRow(title: "Headless Virtual Display", kind: .submenu([
                MenuRow(title: "Enabled", kind: .toggle(Prefs.virtualDisplay), action: #selector(toggleVirtualDisplay),
                        tooltip: "Adds a temporary desktop only when no real screen is active. Leave off for ordinary use."),
                MenuRow(title: "When to Use This…", kind: .action, action: #selector(showVirtualDisplayHelp))
            ])),
            MenuRow(title: "Turn Off for Sustained Serious Heat", kind: .toggle(Prefs.stopOnSeriousThermal),
                    action: #selector(toggleSeriousThermal),
                    tooltip: "Turns Keep Awake off after 60 seconds of serious thermal pressure. Critical pressure always turns it off."),
            MenuRow(title: "Personal Hotspot Fallback", kind: .submenu([
                MenuRow(title: "Connect Automatically When Offline", kind: .toggle(Prefs.autoHotspot), action: #selector(toggleAutoHotspot)),
                info("Status: \(hotspot.status)"),
                MenuRow(title: "How This Works…", kind: .action, action: #selector(showHotspotHelp)),
                MenuRow(title: "Location Settings…", kind: .action, action: #selector(openHotspotLocationSettings))
            ])),
            MenuRow(title: "Use Caps Lock as Keep Awake Switch", kind: .toggle(Prefs.capsLockSwitch),
                    action: #selector(toggleCapsLockSwitch), tooltip: "Caps Lock controls Keep Awake without capitalising text."),
            MenuRow(title: "Double-Click Icon to Toggle Keep Awake", kind: .toggle(Prefs.doubleClickToToggle),
                    action: #selector(toggleDoubleClick), tooltip: "Single-click opens this menu after the double-click interval. Right-click opens it immediately."),
            .separator,
            MenuRow(title: "Start at Login", kind: .toggle(LoginItem.isEnabled), action: #selector(toggleLoginItem)),
        ])))
        let typicalTemperature = temperatures.1.map { String(format: "Typical CPU, active + lid open: %.0f–%.0f °C", $0.0, $0.1) } ?? "Typical CPU: collecting readings"
        var details: [MenuRow] = [
            info(typicalTemperature),
            info("Lid \(lidClosed ? "closed" : "open") · sleep \(sleepDisabled ? "blocked" : "normal")"),
        ]
        if let s = snapshot { details.append(info(Describe.displays(s.displays))) }
        if let reason = virtualDisplaySuspensionReason { details.append(warning(reason)) }
        if let problem = sleepRequestProblem { details.append(warning(problem)) }
        if let result = lastResult {
            details.append(result.failed ? warning(result.summary) : info(result.summary))
        } else { details.append(info("No lid test yet")) }
        details += [.separator,
            MenuRow(title: "macOS Sleep & Lock", kind: .submenu(systemTimingRows())),
            MenuRow(title: "Sleep, Lock & Security…", kind: .action, symbol: "lock", action: #selector(showSecurityHelp)),
            MenuRow(title: "Lock Screen Settings…", kind: .action, action: #selector(openLockScreenSettings)),
            .separator,
            MenuRow(title: "Open Event Log", kind: .action, action: #selector(openLog)),
            MenuRow(title: "Open Performance Logs", kind: .action, action: #selector(openPerformanceLog)),
            MenuRow(title: "Copy Diagnostics", kind: .action, action: #selector(copyDiagnostics))]
        rows.append(MenuRow(title: "Diagnostics", kind: .submenu(details)))
        rows.append(.separator)
        rows.append(MenuRow(title: "Quit Caffeine", kind: .action, action: #selector(quit), key: "q"))
        return rows
    }

    @objc private func iconClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        clickTimer?.invalidate()
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) || !Prefs.doubleClickToToggle {
            clicks.cancel()
            showIconMenu()
            return
        }
        let interval = NSEvent.doubleClickInterval
        clicks.receive(clickCount: event.clickCount, at: ProcessInfo.processInfo.systemUptime, interval: interval)
        let timer = Timer(timeInterval: interval + 0.02, repeats: false) { [weak self] _ in
            guard let self, let action = self.clicks.resolve(at: ProcessInfo.processInfo.systemUptime) else { return }
            switch action {
            case .menu: self.showIconMenu()
            case .toggle: self.setWantAwake(!Prefs.wantAwake)
            case .ignore: break
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        clickTimer = timer
    }
    private func showIconMenu() {
        guard let button = statusItem.button else { return }
        statusItem.menu = menu
        defer { statusItem.menu = nil }
        button.performClick(nil)
    }
    @objc private func toggleDoubleClick() {
        Prefs.doubleClickToToggle.toggle()
        clickTimer?.invalidate()
        clicks.cancel()
        updateIcon()
        writeState()
    }

    private func systemTimingRows() -> [MenuRow] {
        var rows = (snapshot?.systemTiming?.rows(onAC: power.onAC) ?? ["Reading system settings…"]).map {
            MenuRow(title: $0, kind: .info,
                    tooltip: "Configured macOS idle policies, refreshed in the background. Lid close, manual sleep and other apps can affect actual behavior.")
        }
        rows += [.separator, MenuRow(title: "Lock Screen Settings…", kind: .action, action: #selector(openLockScreenSettings))]
        return rows
    }

    private func makeItem(_ row: MenuRow) -> NSMenuItem {
        switch row.kind {
        case .separator: return .separator()
        case .section: return .sectionHeader(title: row.title)
        default: break
        }
        let item = NSMenuItem(title: row.title, action: row.action, keyEquivalent: row.key)
        item.target = self
        item.representedObject = row.value
        item.toolTip = row.tooltip
        if let symbol = row.symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        switch row.kind {
        case .headline:
            item.attributedTitle = NSAttributedString(string: row.title,
                                                      attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
            item.isEnabled = false
        case .info:
            item.isEnabled = false
        case .warning:
            item.attributedTitle = NSAttributedString(string: row.title, attributes: [.foregroundColor: NSColor.systemOrange])
            item.isEnabled = false
        case .toggle(let on):
            item.state = on ? .on : .off
        case .submenu(let children):
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            children.map(makeItem).forEach(submenu.addItem)
            item.submenu = submenu
        default:
            break
        }
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Fast native sensors also remove a headless display promptly on return to ordinary use.
        readFastSensors()
        updateVirtualDisplay()
        menu.removeAllItems()
        rows().map(makeItem).forEach(menu.addItem)
        refresh()
    }

    // MARK: Actions

    @objc private func toggleAwake() { setWantAwake(!Prefs.wantAwake) }

    @objc private func toggleCapsLockSwitch() {
        if Prefs.capsLockSwitch {
            Prefs.capsLockSwitch = false; capsSwitch.stop(); writeState(); return
        }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Use Caps Lock as a switch?"
        alert.informativeText = "Caps Lock becomes a dedicated Keep Awake switch and will not capitalise text or passwords. Its light briefly blinks every five seconds, or blinks faster with an inactivity timer. Your original Caps Lock mapping returns when you disable this option or quit."
        alert.addButton(withTitle: "Enable"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Prefs.capsLockSwitch = true; capsSwitch.start(); writeState()
    }

    @objc private func toggleAutoHotspot() {
        if Prefs.autoHotspot { Prefs.autoHotspot = false; hotspot.stop(); return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Enable Personal Hotspot Fallback?"
        alert.informativeText = "Caffeine checks internet access using Apple and Cloudflare, and may switch to your recent Personal Hotspot when offline. Switching can interrupt connections and use mobile data. macOS requires Location permission to read Wi-Fi names. This feature is experimental."
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Prefs.autoHotspot = true
        if hotspotLocation.authorizationStatus == .notDetermined { hotspotLocation.requestWhenInUseAuthorization() }
        hotspot.start()
    }

    @objc private func showHotspotHelp() {
        showAlert("Personal Hotspot Fallback", "Off by default. Caffeine checks internet access through Apple and Cloudflare. After three failed checks it tries your most recently connected Personal Hotspot, waiting at least five minutes before trying again. The Apple device must be nearby and available through Instant Hotspot. Wi-Fi scanning needs Location permission. This experimental feature uses undocumented macOS interfaces, may interrupt connections and can use mobile data. Caffeine does not store the hotspot password.")
    }

    @objc private func openHotspotLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") { NSWorkspace.shared.open(url) }
    }

    private func setWantAwake(_ on: Bool) {
        if on && (Prefs.thermalStopPending || thermal == "critical" || (Prefs.stopOnSeriousThermal && thermal == "serious")) {
            log("thermal_reenable_blocked", ["thermal": thermal])
            return
        }
        if on { Prefs.thermalStopReason = nil }
        Prefs.idleSleepPending = false
        lastIdleSleepAttempt = nil
        sleepRequestProblem = nil
        idleArmedAt = ProcessInfo.processInfo.systemUptime
        Prefs.wantAwake = on
        lastApply = .distantPast
        permissionProblem = nil
        log(on ? "turned_on" : "turned_off")
        readFastSensors()
        reconcile()
        updateIcon()
        writeState()
    }

    @objc private func selectIdleSleep(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let minutes = Int(value), (0...1440).contains(minutes) else { return }
        setIdleSleep(minutes)
    }

    private func setIdleSleep(_ minutes: Int) {
        Prefs.idleSleepMinutes = minutes
        Prefs.idleSleepPending = false
        lastIdleSleepAttempt = nil
        sleepRequestProblem = nil
        idleArmedAt = ProcessInfo.processInfo.systemUptime
        Prefs.persistSafetyState()
        log("idle_timer_changed", ["minutes": minutes])
        writeState()
    }

    @objc private func disableScheduledRestart() {
        let current = RestartSchedule.read()
        guard current.enabled else { return }
        configureRestart(enabled: false, hour: current.hour, minute: current.minute)
    }

    @objc private func defaultScheduledRestart() { configureRestart(enabled: true, hour: 5, minute: 0) }

    @objc private func customScheduledRestart() {
        NSApp.activate()
        let current = RestartSchedule.read()
        let alert = NSAlert(); alert.messageText = "Daily forced restart time"
        alert.informativeText = "Enter a local time in 24-hour format, such as 05:00. The restart forces apps to close and unsaved work will be lost."
        let field = NSTextField(string: String(format: "%02d:%02d", current.hour, current.minute))
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 24); alert.accessoryView = field
        alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let (hour, minute) = RestartSchedule.parseTime(field.stringValue.trimmingCharacters(in: .whitespaces)) else {
            showAlert("Enter a time", "Use a 24-hour time, such as 05:00."); return
        }
        configureRestart(enabled: true, hour: hour, minute: minute)
    }

    private func configureRestart(enabled: Bool, hour: Int, minute: Int) {
        if enabled {
            guard LoginItem.isEnabled else {
                showAlert("Enable Start at Login first", "Caffeine needs Start at Login to resume its safety checks after you sign in."); return
            }
            NSApp.activate()
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = "Enable daily forced restart?"
            alert.informativeText = "At \(String(format: "%02d:%02d", hour, minute)) the Mac will force-restart, including at the login screen. Unsaved work and running tasks will be lost. The schedule continues even if Caffeine is quit; turn it off before uninstalling. Caffeine will request Keep Awake after reboot when its safety guards permit. Administrator authentication is required."
            alert.addButton(withTitle: "Enable Forced Restart"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        // Ensure the pre-login helper has a real, user-owned preferences file.
        Prefs.wantAwake = Prefs.wantAwake
        Prefs.persistSafetyState()
        if let error = RestartSchedule.configure(enabled: enabled, hour: hour, minute: minute) {
            showAlert("Could not update restart schedule", error)
        } else { log("restart_schedule_changed", ["enabled": enabled, "hour": hour, "minute": minute]) }
        writeState()
    }

    @objc private func customIdleSleep() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Sleep after inactivity"
        alert.informativeText = "Enter 1–1440 minutes without keyboard or mouse activity. Caffeine turns off and requests sleep, even if background work is running."
        let field = NSTextField(string: Prefs.idleSleepMinutes == 0 ? "60" : String(Prefs.idleSleepMinutes))
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let minutes = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), (1...1440).contains(minutes) else {
            showAlert("Choose 1–1440 minutes", "Enter a whole number of minutes."); return
        }
        setIdleSleep(minutes)
    }

    @objc private func toggleVirtualDisplay() {
        Prefs.virtualDisplay.toggle()
        reconcile()
        writeState()
    }

    @objc private func toggleSeriousThermal() {
        Prefs.stopOnSeriousThermal.toggle()
        log("serious_thermal_policy_changed", ["enabled": Prefs.stopOnSeriousThermal])
        reconcile()
        writeState()
    }

    @objc private func toggleAllowOnBattery() {
        Prefs.allowOnBattery.toggle()
        reconcile()
        writeState()
    }

    @objc private func selectBatteryCutoff(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let percent = Int(value) else { return }
        setBatteryCutoff(percent)
    }

    private func setBatteryCutoff(_ percent: Int) {
        guard (5...80).contains(percent) else { return }
        Prefs.minBatteryPercent = percent
        log("battery_cutoff", ["percent": percent])
        reconcile()
        updateIcon()
        writeState()
    }

    @objc private func customBatteryCutoff() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Battery cutoff"
        alert.informativeText = "Pause Keep Awake at or below this battery percentage (5–80). A low cutoff leaves less reserve."
        let field = NSTextField(string: String(Prefs.minBatteryPercent))
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            guard let percent = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), (5...80).contains(percent) else {
                showAlert("Choose 5–80%", "Enter a whole battery percentage from 5 to 80.")
                return
            }
            setBatteryCutoff(percent)
        }
    }

    @objc private func toggleLoginItem() {
        setLoginItem(!LoginItem.isEnabled)
        writeState()
    }

    private func setLoginItem(_ on: Bool) {
        guard on != LoginItem.isEnabled else { return }
        if !on && RestartSchedule.read().enabled {
            showAlert("Daily restart requires Start at Login", "Turn off Daily Forced Restart before disabling Start at Login, so Caffeine can resume its safety checks after sign-in.")
            return
        }
        if on {
            do {
                try LoginItem.enable()
                log("login_item_on")
            } catch {
                log("login_item_failed", ["reason": error.localizedDescription])
                showAlert("Couldn't add the login item", error.localizedDescription)
            }
        } else {
            LoginItem.disable()
            log("login_item_off")
        }
    }

    @objc private func showVirtualDisplayHelp() {
        showAlert(CaffeineHelp.virtualDisplayTitle, CaffeineHelp.virtualDisplayText)
    }

    @objc private func showSecurityHelp() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = CaffeineHelp.securityTitle
        alert.informativeText = CaffeineHelp.securityText
        alert.addButton(withTitle: "Lock Screen Settings…")
        alert.addButton(withTitle: "Apple Security Guide")
        alert.addButton(withTitle: "Done")
        switch alert.runModal() {
        case .alertFirstButtonReturn: openLockScreenSettings()
        case .alertSecondButtonReturn: NSWorkspace.shared.open(CaffeineHelp.appleSecurityURL)
        default: break
        }
    }

    @objc private func openLockScreenSettings() {
        log("open_lock_screen_settings")
        let url = URL(string: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension")!
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }

    @objc private func openPerformanceLog() {
        try? FileManager.default.createDirectory(at: PerformanceLog.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(PerformanceLog.directory)
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(EventLog.file)
    }

    @objc private func copyDiagnostics() {
        guard let snapshot else { refresh(); return }
        let report = Describe.report(snapshot, app: AppState.load())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    @objc private func showPermissionHelp() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "One-time permission needed"
        alert.informativeText = """
            Caffeine changes the lid-close sleep setting with `pmset -a disablesleep 0|1`, which needs root.

            The setup command installs a sudoers rule that allows exactly those two commands without a password, nothing else. Paste it into Terminal and enter your password once.

            To revoke later: sudo rm \(Pmset.sudoersPath)
            """
        alert.addButton(withTitle: "Copy Setup Command")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Pmset.permissionCommand(), forType: .string)
        }
    }

    private func showAlert(_ title: String, _ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Commands (from `Caffeine --on`, `--off`, …)

    @objc private func handleCommand(_ note: Notification) {
        guard let raw = note.object as? String else { return }
        let parts = raw.split(separator: "@", maxSplits: 1).map(String.init)
        let command = parts.first ?? ""
        let commandID = parts.count > 1 ? parts[1] : nil
        log("command", ["command": command])

        switch command {
        case "on": setWantAwake(true)
        case "off": setWantAwake(false)
        case "refresh": refresh(commandID: commandID); return
        case "quit": NSApp.terminate(nil); return
        case "handoff":
            // Only the login item's own instance asks for this, when it takes over from a manual launch.
            guard LoginItem.isEnabled else { return }
            handingOff = true
            NSApp.terminate(nil)
            return
        case _ where command.hasPrefix("set:"):
            let kv = command.dropFirst(4).split(separator: "=").map(String.init)
            if kv.count == 2 {
                switch kv[0] {
                case "virtualDisplay": Prefs.virtualDisplay = kv[1] == "1"
                case "doubleClickToToggle": Prefs.doubleClickToToggle = kv[1] == "1"
                case "allowOnBattery": Prefs.allowOnBattery = kv[1] == "1"
                case "stopOnSeriousThermal": Prefs.stopOnSeriousThermal = kv[1] == "1"
                case "startAtLogin": setLoginItem(kv[1] == "1")
                case "minBatteryPercent":
                    if let percent = Int(kv[1]), (5...80).contains(percent) { setBatteryCutoff(percent) }
                default: break
                }
            }
            reconcile()
        case _ where command.hasPrefix("sim:"):
            // Fake sensor readings to exercise the guards end to end. Only in debug launches.
            guard debug else { return }
            let spec = command.dropFirst(4)
            if spec == "clear" {
                simulation = [:]
                simulatedVirtualDisplay = false
            } else {
                for pair in spec.split(separator: ",") {
                    let kv = pair.split(separator: "=").map(String.init)
                    if kv.count == 2 { simulation[kv[0]] = kv[1] }
                }
            }
            log("simulation", ["spec": String(spec)])
            tick()
        default:
            return
        }
        lastCommandID = commandID
        writeState()
    }
}
