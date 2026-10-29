import Foundation
import IOKit

// Private read-only IOKit HID interfaces; unavailable sensors are reported as unavailable.
@_silgen_name("IOHIDEventSystemClientCreate") private func hidCreate(_ allocator: CFAllocator?) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDEventSystemClientSetMatching") private func hidMatch(_ client: CFTypeRef, _ matching: CFDictionary)
@_silgen_name("IOHIDEventSystemClientCopyServices") private func hidServices(_ client: CFTypeRef) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty") private func hidProperty(_ service: CFTypeRef, _ key: CFString) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDServiceClientCopyEvent") private func hidEvent(_ service: CFTypeRef, _ type: Int64, _ a: Int32, _ b: Int64) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDEventGetFloatValue") private func hidValue(_ event: CFTypeRef, _ field: Int32) -> Double

enum ChipTemperature {
    static func read() -> Double? {
        guard let client = hidCreate(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        hidMatch(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        guard let services = hidServices(client)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        var readings: [Double] = []
        for service in services {
            guard let name = hidProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                  name.hasPrefix("pACC MTR Temp Sensor") || name.hasPrefix("eACC MTR Temp Sensor"),
                  let event = hidEvent(service, 15, 0, 0)?.takeRetainedValue() else { continue }
            let degrees = hidValue(event, 15 << 16)
            if degrees.isFinite && (0...120).contains(degrees) { readings.append(degrees) }
        }
        return readings.max()
    }
}
