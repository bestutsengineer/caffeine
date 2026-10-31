import Foundation
import CoreWLAN
import CoreLocation

/// Network checks run only while enabled. The private API runs in a separate process.
final class HotspotMonitor: NSObject, CWEventDelegate {
    private let queue = DispatchQueue(label: "caffeine.hotspot", qos: .utility)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var worker: Process?
    private var generation = 0
    private var policy = HotspotRetryPolicy()
    private var probeTiming = HotspotProbeTiming()
    private var lastOfflineStatus: String?
    private var message = "Off"
    private var previousOnline: Bool?
    private var trackedHotspot: String?
    private var wifiClient: CWWiFiClient?
    private var wifiChangeGeneration = 0
    private let locationManager = CLLocationManager()

    var status: String { lock.lock(); defer { lock.unlock() }; return message }

    func start() {
        stop()
        lock.lock()
        generation += 1
        let run = generation
        message = Prefs.hotspotPausedAfterDisconnect ? "Paused after hotspot disconnect; turn off and on to resume" : "Checking internet"
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        lock.unlock()
        timer.schedule(deadline: .now(), repeating: 10, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.check(run: run) }
        timer.resume()
        let client = CWWiFiClient.shared()
        client.delegate = self
        do {
            try client.startMonitoringEvent(with: .ssidDidChange)
            try client.startMonitoringEvent(with: .powerDidChange)
            wifiClient = client
            queue.async { [weak self] in
                guard let self, self.isCurrent(run), !Prefs.hotspotPausedAfterDisconnect else { return }
                self.trackCurrentHotspot(reportUnavailable: false)
            }
        } catch {
            try? client.stopMonitoringAllEvents()
            client.delegate = nil
            EventLog.write("hotspot_disconnect_monitor_unavailable", [:])
        }
    }

    func stop() {
        lock.lock(); generation += 1; let old = timer; timer = nil; message = "Off"
        if let worker, worker.isRunning {
            EventLog.write("hotspot_attempt_cancelled", ["reason": "monitor_stopped"])
            worker.terminate()
        }
        lock.unlock()
        old?.cancel()
        if let client = wifiClient { try? client.stopMonitoringAllEvents(); client.delegate = nil; wifiClient = nil }
        queue.async { [weak self] in
            self?.policy.reset()
            self?.probeTiming.reset()
            self?.lastOfflineStatus = nil
            self?.previousOnline = nil
            self?.trackedHotspot = nil
            self?.wifiChangeGeneration += 1
        }
    }

    private func isCurrent(_ run: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }; return generation == run
    }
    private func setStatus(_ value: String, run: Int) {
        lock.lock(); defer { lock.unlock() }
        if generation == run { message = value }
    }

    private func check(run: Int) {
        guard isCurrent(run), !Prefs.hotspotPausedAfterDisconnect, probeTiming.shouldStart(now: ProcessInfo.processInfo.systemUptime) else { return }
        let online = Self.internetAvailable()
        guard isCurrent(run) else { return }
        if previousOnline != online {
            EventLog.write("hotspot_connectivity_changed", ["online": online])
            previousOnline = online
        }
        if online {
            lastOfflineStatus = nil
            _ = policy.observe(online: true, now: ProcessInfo.processInfo.systemUptime)
            setStatus("Internet available", run: run)
            return
        }
        guard policy.observe(online: false, now: ProcessInfo.processInfo.systemUptime) else {
            setStatus(lastOfflineStatus ?? "Internet unavailable; waiting", run: run)
            return
        }
        // A Wi-Fi notification may be queued behind the internet probe.
        if let interface = CWWiFiClient.shared().interface(), pauseIfDisconnected(interface) { return }
        setStatus("Trying recent Personal Hotspot", run: run)
        let process = Process()
        guard let executable = Bundle.main.executableURL else { lastOfflineStatus = "Hotspot worker unavailable"; setStatus(lastOfflineStatus!, run: run); EventLog.write("hotspot_attempt_finished", ["outcome": "worker_unavailable"]); return }
        process.executableURL = executable
        process.arguments = ["--hotspot-worker"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        lock.lock()
        guard generation == run else { lock.unlock(); return }
        do { try process.run(); worker = process; EventLog.write("hotspot_attempt_started", [:]); lock.unlock() }
        catch { lock.unlock(); lastOfflineStatus = "Hotspot worker unavailable"; setStatus(lastOfflineStatus!, run: run); EventLog.write("hotspot_attempt_finished", ["outcome": "worker_launch_failed"]); return }
        let timeout = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 45, execute: timeout)
        process.waitUntilExit(); timeout.cancel()
        lock.lock(); if worker === process { worker = nil }; lock.unlock()
        guard isCurrent(run) else { return }
        let status = process.terminationReason == .exit ? process.terminationStatus : -1
        if status == 0 { setStatus("Joined; checking internet", run: run) }
        else if status == 4 { setStatus("Internet restored; no switch needed", run: run) }
        else { setStatus(statusMessage(for: status), run: run) }
        let outcomes: [Int32: String] = [0: "associated", 2: "unavailable", 3: "already_associated", 4: "internet_recovered", 5: "wifi_unavailable", 6: "no_saved_hotspot", 7: "discovery_failed", 8: "not_in_scan", 9: "scan_failed", 10: "association_failed"]
        lastOfflineStatus = status == 0 || status == 4 ? nil : statusMessage(for: status)
        EventLog.write("hotspot_attempt_finished", ["result": Int(status), "outcome": outcomes[status] ?? "worker_failed_or_timed_out"])
        if status == 0 {
            trackCurrentHotspot(reportUnavailable: true)
            let connected = Self.internetAvailable()
            guard isCurrent(run) else { return }
            EventLog.write("hotspot_internet_after_join", ["online": connected])
            if !connected {
                lastOfflineStatus = "Hotspot joined; internet unavailable"
                setStatus("Hotspot joined; internet unavailable", run: run)
            }
        }
    }

    private func locationAuthorized() -> Bool {
        return locationManager.authorizationStatus == .authorizedAlways
    }

    private func trackCurrentHotspot(reportUnavailable: Bool) {
        guard locationAuthorized(), let wifi = CWWiFiClient.shared().interface(),
              let current = wifi.ssid(), !current.isEmpty,
              current == HotspotWorker.lastHotspot(wifi: wifi) else {
            if reportUnavailable { EventLog.write("hotspot_disconnect_monitor_unavailable", ["reason": "hotspot_not_identified"]) }
            return
        }
        trackedHotspot = current
        EventLog.write("hotspot_disconnect_monitor_started", [:])
    }

    func ssidDidChangeForWiFiInterface(withName interfaceName: String) { scheduleWifiCheck(interfaceName) }
    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { scheduleWifiCheck(interfaceName) }
    private func scheduleWifiCheck(_ interfaceName: String) {
        queue.async { [weak self] in
            guard let self, self.trackedHotspot != nil, !Prefs.hotspotPausedAfterDisconnect else { return }
            self.wifiChangeGeneration += 1
            let change = self.wifiChangeGeneration
            self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.wifiChangeGeneration == change,
                      let interface = CWWiFiClient.shared().interface(), interface.interfaceName == interfaceName else { return }
                _ = self.pauseIfDisconnected(interface)
            }
        }
    }

    @discardableResult private func pauseIfDisconnected(_ interface: CWInterface) -> Bool {
        guard trackedHotspot != nil else { return false }
        guard locationAuthorized() else {
            trackedHotspot = nil
            EventLog.write("hotspot_disconnect_monitor_unavailable", ["reason": "location_unavailable"])
            return false
        }
        guard HotspotDisconnectPolicy.shouldPause(tracked: trackedHotspot, current: interface.ssid(), locationAuthorized: true) else { return false }
        trackedHotspot = nil
        Prefs.hotspotPausedAfterDisconnect = true
        lock.lock(); message = "Paused after hotspot disconnect; turn off and on to resume"; lock.unlock()
        EventLog.write("hotspot_fallback_paused", ["reason": "hotspot_disconnected", "cause": "unknown"])
        return true
    }

    private func statusMessage(for result: Int32) -> String {
        switch result {
        case 2: return "Wi-Fi off or recent hotspot unavailable"
        case 3: return "Hotspot connected, but internet unavailable"
        case 5: return "Wi-Fi unavailable or off"
        case 6: return "No recent Personal Hotspot found"
        case 7: return "Personal Hotspot could not be discovered"
        case 8: return "Personal Hotspot did not appear in Wi-Fi scan"
        case 9: return "Wi-Fi scan failed; check Location access"
        case 10: return "Could not join Personal Hotspot"
        default: return "Could not join hotspot; will retry"
        }
    }

    static func internetAvailable() -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        let group = DispatchGroup(), resultLock = NSLock()
        var success = false
        let urls = ["https://captive.apple.com/hotspot-detect.html", "https://www.cloudflare.com/cdn-cgi/trace"]
        var tasks: [URLSessionDataTask] = []
        for (index, address) in urls.enumerated() {
            guard let url = URL(string: address) else { continue }
            group.enter()
            let task = session.dataTask(with: url) { data, response, _ in
                defer { group.leave() }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data, let body = String(data: data, encoding: .utf8) else { return }
                let valid = index == 0 ? body.contains("Success") : body.contains("fl=")
                if valid { resultLock.lock(); success = true; resultLock.unlock() }
            }
            tasks.append(task); task.resume()
        }
        _ = group.wait(timeout: .now() + 12)
        tasks.forEach { $0.cancel() }
        session.invalidateAndCancel()
        resultLock.lock(); defer { resultLock.unlock() }; return success
    }
}
