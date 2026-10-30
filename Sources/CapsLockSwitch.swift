import AppKit
import IOKit.hid
import Carbon

enum CapsSwitchPolicy {
    static func light(on: Bool, timer: Bool, phase: Bool, markerPulse: Bool = false) -> Bool {
        on && (timer ? phase : !markerPulse)
    }
}

enum CapsMappingPolicy {
    static let sourceKey = "HIDKeyboardModifierMappingSrc"
    static let destinationKey = "HIDKeyboardModifierMappingDst"
    static let caps: UInt64 = 0x700000039
    static func replacingCaps(in rows: [[String: UInt64]], with replacement: [[String: UInt64]]) -> [[String: UInt64]] {
        rows.filter { $0[sourceKey] != caps } + replacement
    }
    static func owns(_ rows: [[String: UInt64]], destination: UInt64) -> Bool {
        rows.contains { $0[sourceKey] == caps && $0[destinationKey] == destination }
    }
}

/// Repurposes the physical key without enabling the Caps Lock typing modifier.
/// No key contents are read or recorded. Existing mappings are restored on normal exit.
final class CapsLockSwitch {
    private struct Saved: Codable {
        var boot: String
        var entries: [String: Entry]
    }
    private struct Entry: Codable {
        var original: [[String: UInt64]]
        var destination: UInt64
    }
    private let recordURL = SleepOwnership.directory.appendingPathComponent("caps-key-mapping.json")
    private var saved = Saved(boot: "", entries: [:])
    private var timer: Timer?
    private var connection: io_connect_t = 0
    private var client: IOHIDEventSystemClient?
    private var ledClient: IOHIDEventSystemClient?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var destination: UInt64 = 0
    private var keyHeld = false
    private var phase = false
    private var ticks = 0
    private var lastLED: Bool?
    private var ledRetryAfter: TimeInterval = 0
    private var lastError: String?
    private let desired: () -> (on: Bool, blink: Bool)
    private let change: (Bool) -> Void
    private let report: (String?) -> Void

    init(desired: @escaping () -> (Bool, Bool), change: @escaping (Bool) -> Void, report: @escaping (String?) -> Void) {
        self.desired = desired; self.change = change; self.report = report
    }

    func start() {
        guard timer == nil else { return }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { updateError("Caps Lock switch unavailable"); return }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection) == KERN_SUCCESS else {
            connection = 0; updateError("Caps Lock switch unavailable"); return
        }
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        guard IOHIDSetModifierLockState(connection, Int32(kIOHIDCapsLockState), false) == KERN_SUCCESS,
              let boot = SleepOwnership.bootID() else { failStart(); return }
        self.client = client
        self.ledClient = CaffeineCreateLEDClient()?.takeRetainedValue()
        saved = (try? Data(contentsOf: recordURL)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved(boot: boot, entries: [:])
        if saved.boot != boot { saved = Saved(boot: boot, entries: [:]) }
        restoreMappings()
        guard registerShortcut() else { failStart(); return }
        guard updateMappings() else { failStart(); return }
        ticks = 0; phase = false; lastLED = nil; ledRetryAfter = 0
        poll()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }

    func stop() {
        timer?.invalidate(); timer = nil
        restoreMappings()
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        restoreLED()
        if connection != 0 { _ = IOHIDSetModifierLockState(connection, Int32(kIOHIDCapsLockState), false); IOServiceClose(connection); connection = 0 }
        client = nil; ledClient = nil; keyHeld = false; lastLED = nil
        updateError(nil)
    }

    private func failStart() { stop(); updateError("Caps Lock switch unavailable; normal keyboard mapping restored") }

    private func keyboards(_ system: IOHIDEventSystemClient?) -> [IOHIDServiceClient] {
        guard let system, let services = IOHIDEventSystemClientCopyServices(system) as? [IOHIDServiceClient] else { return [] }
        return services.filter { IOHIDServiceClientConformsTo($0, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Keyboard)) != 0 }
    }

    private func rows(_ service: IOHIDServiceClient) -> [[String: UInt64]] {
        IOHIDServiceClientCopyProperty(service, "UserKeyMapping" as CFString) as? [[String: UInt64]] ?? []
    }
    private func key(_ service: IOHIDServiceClient) -> String { (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.stringValue ?? "" }
    private func persist() -> Bool {
        do {
            try FileManager.default.createDirectory(at: recordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(saved).write(to: recordURL, options: .atomic)
            return true
        } catch { return false }
    }
    private func restoreMappings() {
        for service in keyboards(client) {
            let id = key(service)
            guard let entry = saved.entries[id] else { continue }
            let current = rows(service)
            if CapsMappingPolicy.owns(current, destination: entry.destination) {
                let restored = CapsMappingPolicy.replacingCaps(in: current, with: entry.original)
                guard IOHIDServiceClientSetProperty(service, "UserKeyMapping" as CFString, restored as CFArray) else { continue }
            }
            saved.entries.removeValue(forKey: id)
        }
        if !saved.boot.isEmpty { _ = persist() }
    }
    private func updateMappings() -> Bool {
        let services = keyboards(client)
        guard !services.isEmpty else { return false }
        for service in services {
            let id = key(service), current = rows(service)
            guard !id.isEmpty else { return false }
            if let entry = saved.entries[id] {
                guard CapsMappingPolicy.owns(current, destination: entry.destination) else { return false }
                continue
            }
            // Record before changing anything so a crash can be recovered on next launch.
            saved.entries[id] = Entry(original: current.filter { $0[CapsMappingPolicy.sourceKey] == CapsMappingPolicy.caps }, destination: destination)
            guard persist() else { return false }
            let replacement = [[CapsMappingPolicy.sourceKey: CapsMappingPolicy.caps, CapsMappingPolicy.destinationKey: destination]]
            let updated = CapsMappingPolicy.replacingCaps(in: current, with: replacement)
            guard IOHIDServiceClientSetProperty(service, "UserKeyMapping" as CFString, updated as CFArray),
                  CapsMappingPolicy.owns(rows(service), destination: destination) else { return false }
        }
        return true
    }

    private func registerShortcut() -> Bool {
        let existing = keyboards(client).flatMap { rows($0) }
        let choices: [(UInt32, UInt64)] = [(UInt32(kVK_F20), 0x70000006f), (UInt32(kVK_F19), 0x70000006e),
                                          (UInt32(kVK_F18), 0x70000006d), (UInt32(kVK_F17), 0x70000006c), (UInt32(kVK_F16), 0x70000006b)]
        let userData = Unmanaged.passUnretained(self).toOpaque()
        var events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        guard InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<CapsLockSwitch>.fromOpaque(context).takeUnretainedValue()
            if GetEventKind(event) == UInt32(kEventHotKeyReleased) { owner.keyHeld = false }
            else if !owner.keyHeld { owner.keyHeld = true; owner.change(!owner.desired().on) }
            return noErr
        }, events.count, &events, userData, &handler) == noErr else { return false }
        for (virtualKey, usage) in choices where !existing.contains(where: { $0[CapsMappingPolicy.sourceKey] == usage || $0[CapsMappingPolicy.destinationKey] == usage }) {
            if RegisterEventHotKey(virtualKey, 0, EventHotKeyID(signature: 0x43616665, id: 1), GetApplicationEventTarget(), 0, &hotKey) == noErr {
                destination = usage; return true
            }
        }
        return false
    }

    private func poll() {
        // Keep the typing modifier off even if other software tries to enable it.
        var state = false
        if IOHIDGetModifierLockState(connection, Int32(kIOHIDCapsLockState), &state) == KERN_SUCCESS, state {
            _ = IOHIDSetModifierLockState(connection, Int32(kIOHIDCapsLockState), false)
        }
        ticks += 1
        if ticks % 20 == 0, !updateMappings() { updateError("Caps Lock keyboard mapping unavailable"); return }
        if ticks % 4 == 0 { phase.toggle() }
        let wanted = desired()
        let value = CapsSwitchPolicy.light(on: wanted.on, timer: wanted.blink, phase: phase, markerPulse: ticks % 20 == 0)
        let now = ProcessInfo.processInfo.systemUptime
        if lastLED != value && now >= ledRetryAfter {
            if setLED(value) { lastLED = value; ledRetryAfter = 0; updateError(nil) }
            else { ledRetryAfter = now + 5; updateError("Caps Lock light unavailable") }
        }
    }
    private func setLED(_ on: Bool) -> Bool {
        let services = keyboards(ledClient)
        return !services.isEmpty && services.map { IOHIDServiceClientSetProperty($0, "HIDCapsLockLED" as CFString, (on ? "On" : "Off") as CFString) }.contains(true)
    }
    private func restoreLED() {
        for service in keyboards(ledClient) { _ = IOHIDServiceClientSetProperty(service, "HIDCapsLockLED" as CFString, "Auto" as CFString) }
    }
    private func updateError(_ value: String?) {
        guard lastError != value else { return }; lastError = value; report(value)
    }
}
