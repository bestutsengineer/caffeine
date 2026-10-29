import Foundation

/// Network checks run only while enabled. The private API runs in a separate process.
final class HotspotMonitor {
    private let queue = DispatchQueue(label: "caffeine.hotspot", qos: .utility)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var worker: Process?
    private var generation = 0
    private var policy = HotspotRetryPolicy()
    private var message = "Off"

    var status: String { lock.lock(); defer { lock.unlock() }; return message }

    func start() {
        stop()
        lock.lock()
        generation += 1
        let run = generation
        message = "Checking internet"
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        lock.unlock()
        timer.schedule(deadline: .now(), repeating: 60, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.check(run: run) }
        timer.resume()
    }

    func stop() {
        lock.lock(); generation += 1; let old = timer; timer = nil; message = "Off"
        if let worker, worker.isRunning { worker.terminate() }
        lock.unlock()
        old?.cancel()
        queue.async { [weak self] in self?.policy.reset() }
    }

    private func isCurrent(_ run: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }; return generation == run
    }
    private func setStatus(_ value: String, run: Int) {
        lock.lock(); defer { lock.unlock() }
        if generation == run { message = value }
    }

    private func check(run: Int) {
        guard isCurrent(run) else { return }
        let online = Self.internetAvailable()
        guard isCurrent(run) else { return }
        if online {
            _ = policy.observe(online: true, now: ProcessInfo.processInfo.systemUptime)
            setStatus("Internet available", run: run)
            return
        }
        guard policy.observe(online: false, now: ProcessInfo.processInfo.systemUptime) else {
            setStatus("Internet unavailable; waiting", run: run)
            return
        }
        setStatus("Trying recent Personal Hotspot", run: run)
        let process = Process()
        guard let executable = Bundle.main.executableURL else { setStatus("Hotspot worker unavailable", run: run); return }
        process.executableURL = executable
        process.arguments = ["--hotspot-worker"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        lock.lock()
        guard generation == run else { lock.unlock(); return }
        do { try process.run(); worker = process; lock.unlock() }
        catch { lock.unlock(); setStatus("Hotspot worker unavailable", run: run); return }
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
        switch status {
        case 0: setStatus("Joined; checking internet", run: run)
        case 2: setStatus("Wi-Fi off or recent hotspot unavailable", run: run)
        case 3: setStatus("Hotspot connected, but internet unavailable", run: run)
        case 4: setStatus("Internet restored; no switch needed", run: run)
        default: setStatus("Could not join hotspot; will retry", run: run)
        }
        EventLog.write("hotspot_attempt_finished", ["result": Int(status)])
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
