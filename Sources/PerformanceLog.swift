import Foundation
import Darwin

enum PerformanceLog {
    static let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/Caffeine/performance", isDirectory: true)
    private static let queue = DispatchQueue(label: "caffeine.performance", qos: .utility)
    private static var previous: [UInt32]?
    private static let lock = NSLock()
    private static var currentTemperature: Double?
    private static var temperatureRange: (Double, Double)?
    private static var lastRangeRefresh = Date.distantPast
    static func temperatureSummary() -> (Double?, (Double, Double)?) {
        lock.lock(); defer { lock.unlock() }
        return (currentTemperature, temperatureRange)
    }
    private static func setSummary(current: Double?, range: (Double, Double)?) {
        lock.lock(); currentTemperature = current; temperatureRange = range; lock.unlock()
    }
    static func typicalRange(now: Date, directory dir: URL = directory) -> (Double, Double)? {
        let cutoff = Int(now.timeIntervalSince1970 - retention)
        var samples: [(Int, Double)] = []
        for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            guard file.lastPathComponent.hasPrefix("sample-"), file.pathExtension == "csv", let data = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for row in data.split(separator: "\n") {
                let fields = row.split(separator: ",", omittingEmptySubsequences: false)
                if fields.count >= 5, fields[4] == "1", let t = Int(fields[0]), t >= cutoff, t <= Int(now.timeIntervalSince1970), let value = Double(fields[3]), value.isFinite, (0...120).contains(value) { samples.append((t,value)) }
            }
        }
        guard samples.count >= 30, let earliest = samples.map({ $0.0 }).min(), let latest = samples.map({ $0.0 }).max(), latest - earliest >= 1800 else { return nil }
        let sorted = samples.map { $0.1 }.sorted()
        return (sorted[(sorted.count - 1) * 5 / 100], sorted[(sorted.count - 1) * 95 / 100])
    }
    private static let retention: TimeInterval = 30 * 24 * 60 * 60
    static func prime() {
        queue.async {
            previous = cpuTicks()
            let now = Date(); prune(now: now)
            setSummary(current: ChipTemperature.read(), range: typicalRange(now: now))
            lastRangeRefresh = now
        }
    }
    static func sample(thermal: String, activeWithLidOpen: Bool) {
        let captured = Date()
        queue.async {
            let ticks = cpuTicks()
            var percent: Double?
            if let ticks, let old = previous, ticks.count == old.count {
                let delta = zip(ticks, old).map { UInt64($0 &- $1) }
                let total = delta.reduce(0, +)
                if total > 0 { percent = 100 * Double(total - delta[Int(CPU_STATE_IDLE)]) / Double(total) }
            }
            previous = ticks
            let epoch = Int(captured.timeIntervalSince1970)
            let cpu = percent.map { String(format: "%.1f", $0) } ?? ""
            let temperature = ChipTemperature.read()
            let degrees = temperature.map { String(format: "%.1f", $0) } ?? ""
            let line = "\(epoch),\(cpu),\(thermal),\(degrees),\(activeWithLidOpen ? 1 : 0)\n"
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent("sample-\(epoch / 3600).csv")
                if !fm.fileExists(atPath: destination.path) { _ = fm.createFile(atPath: destination.path, contents: nil) }
                let handle = try FileHandle(forWritingTo: destination)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
                prune(now: captured)
                let oldRange = temperatureSummary().1
                let refresh = captured.timeIntervalSince(lastRangeRefresh) >= (oldRange == nil ? 300 : 900)
                setSummary(current: temperature, range: refresh ? typicalRange(now: captured) : oldRange)
                if refresh { lastRangeRefresh = captured }
            } catch { EventLog.write("performance_log_error", ["reason": error.localizedDescription]) }
        }
    }
    private static func cpuTicks() -> [UInt32]? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
    }
    static func prune(now: Date, directory dir: URL = directory) {
        let fm = FileManager.default
        let cutoff = Int(now.timeIntervalSince1970 - retention), boundaryHour = cutoff / 3600
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files {
            let name = file.lastPathComponent
            guard name.hasPrefix("sample-"), name.hasSuffix(".csv"), let hour = Int(name.dropFirst(7).dropLast(4)) else { continue }
            if hour < boundaryHour { try? fm.removeItem(at: file) }
            else if hour == boundaryHour, let contents = try? String(contentsOf: file, encoding: .utf8) {
                let lines = contents.split(separator: "\n")
                let kept = lines.filter { Int($0.split(separator: ",", maxSplits: 1).first ?? "").map { $0 >= cutoff } ?? false }
                if kept.count != lines.count {
                    if kept.isEmpty { try? fm.removeItem(at: file) }
                    else { try? (kept.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8) }
                }
            }
        }
    }
}
