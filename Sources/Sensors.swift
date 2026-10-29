import AppKit
import IOKit
import IOKit.ps

struct PowerState: Codable, Equatable {
    var onAC: Bool
    var batteryPercent: Int?
    var charging: Bool?
    var sourceKnown: Bool? = nil
}

struct DisplayState: Codable, Equatable {
    var active: Int
    var builtinActive: Bool
    var external: Int
    var virtualActive: Bool
    var online: Int? = nil
    var virtualOnline: Bool? = nil
    var builtinOnline: Bool? = nil
    var activeReadStatus: Int32? = nil
    var onlineReadStatus: Int32? = nil
    var externalOnline: Int? = nil
}

enum Sensors {
    static func lidClosed() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return value as? Bool
    }

    static func power() -> PowerState {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return PowerState(onAC: false, sourceKnown: false) }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        var state = PowerState(onAC: providing == kIOPSACPowerValue, sourceKnown: providing != nil)
        let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            if let current = desc[kIOPSCurrentCapacityKey] as? Int,
               let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 {
                state.batteryPercent = current * 100 / max
            }
            state.charging = desc[kIOPSIsChargingKey] as? Bool
        }
        return state
    }

    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static func displays() -> DisplayState {
        func list(online: Bool) -> ([CGDirectDisplayID], CGError) {
            var count: UInt32 = 0
            let first = online ? CGGetOnlineDisplayList(0, nil, &count) : CGGetActiveDisplayList(0, nil, &count)
            guard first == .success, count > 0 else { return ([], first) }
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
            let result = online ? CGGetOnlineDisplayList(count, &ids, &count) : CGGetActiveDisplayList(count, &ids, &count)
            return (result == .success ? Array(ids.prefix(Int(count))) : [], result)
        }
        let (active, activeStatus) = list(online: false)
        let (online, onlineStatus) = list(online: true)
        let virtual = active.filter(VirtualDisplay.isOurs)
        let builtin = active.filter { CGDisplayIsBuiltin($0) != 0 }
        return DisplayState(active: active.count, builtinActive: !builtin.isEmpty,
                            external: active.count - builtin.count - virtual.count, virtualActive: !virtual.isEmpty,
                            online: online.count, virtualOnline: online.contains(where: VirtualDisplay.isOurs),
                            builtinOnline: online.contains { CGDisplayIsBuiltin($0) != 0 },
                            activeReadStatus: activeStatus.rawValue, onlineReadStatus: onlineStatus.rawValue,
                            externalOnline: onlineStatus == .success ? online.filter { CGDisplayIsBuiltin($0) == 0 && !VirtualDisplay.isOurs($0) }.count : nil)
    }
}
