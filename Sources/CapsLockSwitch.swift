import AppKit
import IOKit.hid

enum CapsSwitchAction: Equatable { case synchronize(Bool), userChanged(Bool), none }
enum CapsSwitchPolicy {
    static func action(lastDesired: Bool?, desired: Bool, lastState: Bool?, actual: Bool) -> CapsSwitchAction {
        if lastDesired != desired { return .synchronize(desired) }
        if let lastState, actual != lastState { return .userChanged(actual) }
        return .none
    }
    static func light(on: Bool, timer: Bool, phase: Bool) -> Bool { on && (!timer || phase) }
}

/// Optional physical switch. Only the Caps Lock modifier state is read; no typed keys are captured.
final class CapsLockSwitch {
    private var timer: Timer?
    private var connection: io_connect_t = 0
    private var previousState: Bool?
    private var lastState: Bool?
    private var lastDesired: Bool?
    private var phase = false
    private var phaseTick = 0
    private var lastLED: Bool?
    private var ledRetryAfter: TimeInterval = 0
    private var lastError: String?
    private var manager: IOHIDManager?
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
        guard let initial = read() else { IOServiceClose(connection); connection = 0; updateError("Caps Lock state unavailable"); return }
        previousState = initial; lastState = initial; lastDesired = nil; lastLED = nil; ledRetryAfter = 0
        poll()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if connection != 0 {
            if let previousState { _ = IOHIDSetModifierLockState(connection, Int32(kIOHIDCapsLockState), previousState) }
            IOServiceClose(connection); connection = 0
        }
        if let previousState { _ = setLED(previousState) }
        if let manager { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)); self.manager = nil }
        previousState = nil; lastState = nil; lastDesired = nil; lastLED = nil
        updateError(nil)
    }

    private func read() -> Bool? {
        guard connection != 0 else { return nil }
        var state = false
        return IOHIDGetModifierLockState(connection, Int32(kIOHIDCapsLockState), &state) == KERN_SUCCESS ? state : nil
    }

    private func poll() {
        guard let actual = read() else { updateError("Caps Lock state unavailable"); return }
        let wanted = desired()
        switch CapsSwitchPolicy.action(lastDesired: lastDesired, desired: wanted.on, lastState: lastState, actual: actual) {
        case .synchronize(let value):
            if actual != value {
                guard IOHIDSetModifierLockState(connection, Int32(kIOHIDCapsLockState), value) == KERN_SUCCESS else {
                    updateError("Cannot set Caps Lock state"); return
                }
                lastLED = nil
            }
            lastState = value; lastDesired = value
        case .userChanged:
            self.lastState = actual
            lastLED = nil
            change(actual)
            lastDesired = desired().on
            // A safety guard may reject activation; correct the modifier next tick.
            if lastDesired != actual { lastDesired = nil }
        case .none: break
        }
        let state = desired()
        phaseTick += 1
        if phaseTick >= 4 { phase.toggle(); phaseTick = 0 }
        let led = CapsSwitchPolicy.light(on: state.on, timer: state.blink, phase: phase)
        let now = ProcessInfo.processInfo.systemUptime
        if lastLED != led && now >= ledRetryAfter {
            if setLED(led) { lastLED = led; ledRetryAfter = 0; updateError(nil) }
            else { ledRetryAfter = now + 5; updateError("Caps Lock light unavailable") }
        }
    }

    private func updateError(_ value: String?) {
        guard lastError != value else { return }
        lastError = value; report(value)
    }

    /// Set only the hardware LED output; blinking never changes the logical modifier.
    private func setLED(_ on: Bool) -> Bool {
        let manager: IOHIDManager
        if let existing = self.manager { manager = existing }
        else {
            manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            let matching = [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard] as CFDictionary
            IOHIDManagerSetDeviceMatching(manager, matching)
            guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return false }
            self.manager = manager
        }
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return false }
        var success = false
        for device in devices {
            guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else { continue }
            for element in elements where IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_LEDs)
                && IOHIDElementGetUsage(element) == UInt32(kHIDUsage_LED_CapsLock)
                && IOHIDElementGetType(element) == kIOHIDElementTypeOutput {
                let value = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, 0, on ? 1 : 0)
                if IOHIDDeviceSetValue(device, element, value) == kIOReturnSuccess { success = true }
            }
        }
        return success
    }
}
