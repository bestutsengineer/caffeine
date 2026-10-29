import Foundation
import Darwin

/// SleepDisabled is a shared global bit. Only undo a change recorded in this boot.
enum SleepOwnership {
    enum Decision: Equatable { case acquire, keepOwned, keepExternal, release, clearRecord, noChange, unavailable }
    static func decision(want: Bool, actual: Bool?, owned: Bool) -> Decision {
        guard let actual else { return .unavailable }
        if want {
            if actual { return owned ? .keepOwned : .keepExternal }
            return .acquire
        }
        if !owned { return .noChange }
        return actual ? .release : .clearRecord
    }
    static let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Caffeine", isDirectory: true)
    static let record = directory.appendingPathComponent("sleep-override.owner")
    static let lock = directory.appendingPathComponent("sleep-override.lock")
    static func bootID() -> String? {
        var value = timeval(); var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0, value.tv_sec > 0 else { return nil }
        return String(value.tv_sec)
    }
    static func withLock<T>(_ work: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { flock(fd, LOCK_UN) }
        return try work()
    }
    static func isOwned(boot: String, record path: URL = record) -> Bool {
        (try? String(contentsOf: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) == boot
    }
    static func claim(boot: String, record path: URL = record) throws {
        try (boot + "\n").write(to: path, atomically: true, encoding: .utf8)
    }
    static func clear(record path: URL = record) throws {
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
}
