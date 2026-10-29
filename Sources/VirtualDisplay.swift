import CoreGraphics
import Foundation

/// Optional 1920×1080 headless display while the lid is closed and no monitor is attached.
/// Released (and removed) when this object lets go of it.
final class VirtualDisplay {
    static let vendorID: UInt32 = 0x4C41   // "LA"
    static let productID: UInt32 = 0x0001
    static let width: UInt32 = 1920
    static let height: UInt32 = 1080

    private var display: CGVirtualDisplay?
    var isActive: Bool { display != nil }

    static func isOurs(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == vendorID && CGDisplayModelNumber(id) == productID
    }

    @discardableResult
    func create() -> Bool {
        guard display == nil else { return true }
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue.main
        descriptor.name = "Caffeine Virtual Display"
        descriptor.maxPixelsWide = Self.width
        descriptor.maxPixelsHigh = Self.height
        descriptor.sizeInMillimeters = CGSize(width: 527, height: 296)   // ~24"
        descriptor.vendorID = Self.vendorID
        descriptor.productID = Self.productID
        descriptor.serialNum = 1
        descriptor.terminationHandler = { [weak self] _, terminated in
            // A delayed callback from a released display must not clear a newer instance.
            guard let self, let terminated, self.display === terminated else { return }
            self.display = nil
        }

        guard let created = CGVirtualDisplay(descriptor: descriptor) else { return false }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 0
        settings.modes = [CGVirtualDisplayMode(width: Self.width, height: Self.height, refreshRate: 60)]
        guard created.apply(settings) else { return false }
        display = created
        return true
    }

    func destroy() {
        display = nil
    }
}
