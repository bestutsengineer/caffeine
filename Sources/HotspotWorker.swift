import Foundation
import CoreWLAN
import Darwin

/// Runs as a disposable subprocess because the Instant Hotspot API is undocumented.
enum HotspotWorker {
    static func run(inspect: Bool) -> Int32 {
        guard let wifi = CWWiFiClient.shared().interface(), wifi.powerOn() else {
            if inspect { print("Wi-Fi unavailable or off") }
            return inspect ? 2 : 5
        }
        guard let target = lastHotspot(wifi: wifi) else {
            if inspect { print("Recent Personal Hotspot profile unavailable") }
            return inspect ? 2 : 6
        }
        if inspect {
            guard dlopen("/System/Library/PrivateFrameworks/Sharing.framework/Sharing", RTLD_NOW) != nil,
                  let type = NSClassFromString("SFRemoteHotspotSession") as? NSObject.Type else { return 2 }
            let session = type.init()
            let available = ["setDelegate:", "startBrowsing"].allSatisfy { session.responds(to: NSSelectorFromString($0)) }
                && ["enableRemoteHotspotForDevice:withCompletionHandler:", "enableHotspotForDevice:withCompletionHandler:"]
                    .contains { session.responds(to: NSSelectorFromString($0)) }
            print(available ? "Recent hotspot profile and session methods available" : "Instant Hotspot session methods unavailable")
            return available ? 0 : 2
        }
        if wifi.ssid() == target { return 3 }
        var completed = false
        var credentials: (name: String, password: String)?
        let discovery = HotspotDiscovery(name: target) { result in credentials = result; completed = true }
        discovery.start()
        let deadline = Date().addingTimeInterval(22)
        while !completed && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        discovery.stop()
        guard let credentials else { return 7 }
        // Connectivity may have recovered during Bluetooth discovery.
        if HotspotMonitor.internetAvailable() { return 4 }
        // Instant Hotspot may need a moment to start advertising after activation.
        for attempt in 0..<2 {
            let networks: Set<CWNetwork>
            do { networks = try wifi.scanForNetworks(withName: credentials.name) }
            catch { return 9 }
            if let network = networks.first(where: { $0.ssid == credentials.name }) {
                do { try wifi.associate(to: network, password: credentials.password); return 0 }
                catch { return 10 }
            }
            if attempt == 0 { Thread.sleep(forTimeInterval: 2) }
        }
        return 8
    }

    /// These profile properties are not public API and may disappear after an OS update.
    private static func lastHotspot(wifi: CWInterface) -> String? {
        guard let profiles = wifi.configuration()?.networkProfiles.array as? [CWNetworkProfile] else { return nil }
        let values: [HotspotProfile] = profiles.compactMap { profile in
            guard profile.responds(to: NSSelectorFromString("isPersonalHotspot")),
                  profile.responds(to: NSSelectorFromString("lastConnected")),
                  let personal = profile.value(forKey: "isPersonalHotspot") as? NSNumber,
                  let date = profile.value(forKey: "lastConnected") as? Date,
                  let name = profile.ssid else { return nil }
            return HotspotProfile(name: name, lastConnected: date, personal: personal.boolValue)
        }
        return HotspotProfile.mostRecent(in: values)?.name
    }
}

/// Dynamically locates the private Instant Hotspot session at runtime.
final class HotspotDiscovery: NSObject {
    typealias Completion = ((name: String, password: String)?) -> Void
    private let name: String
    private let completion: Completion
    private let sessionFactory: (() -> NSObject?)?
    private var session: NSObject?
    private var callback: (@convention(block) (AnyObject?, AnyObject?) -> Void)?
    private var requested = false
    private var finished = false
    private var library: UnsafeMutableRawPointer?

    init(name: String, sessionFactory: (() -> NSObject?)? = nil, completion: @escaping Completion) {
        self.name = name; self.sessionFactory = sessionFactory; self.completion = completion
    }

    func start() {
        let object: NSObject
        if let sessionFactory {
            guard let fake = sessionFactory() else { finish(nil); return }
            object = fake
        } else {
            library = dlopen("/System/Library/PrivateFrameworks/Sharing.framework/Sharing", RTLD_NOW)
            guard library != nil, let type = NSClassFromString("SFRemoteHotspotSession") as? NSObject.Type else { finish(nil); return }
            object = type.init()
        }
        let delegate = NSSelectorFromString("setDelegate:"), browse = NSSelectorFromString("startBrowsing")
        guard object.responds(to: delegate), object.responds(to: browse) else { finish(nil); return }
        session = object
        _ = object.perform(delegate, with: self)
        _ = object.perform(browse)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.finish(nil) }
    }

    func stop() {
        finished = true
        if let session, session.responds(to: NSSelectorFromString("stopBrowsing")) { _ = session.perform(NSSelectorFromString("stopBrowsing")) }
        if let session, session.responds(to: NSSelectorFromString("setDelegate:")) { _ = session.perform(NSSelectorFromString("setDelegate:"), with: nil) }
        session = nil; callback = nil
        // Keep Sharing loaded until the worker exits, in case callbacks are in flight.
    }
    private func finish(_ value: (name: String, password: String)?) {
        guard !finished else { return }
        stop(); completion(value)
    }

    @objc func updatedFoundDeviceList(_ devices: [NSObject]) { found(devices) }
    @objc func session(_ sender: NSObject, updatedFoundDevices devices: [NSObject]) { found(devices) }
    private func found(_ devices: [NSObject]) {
        guard !finished, !requested, session != nil else { return }
        guard let device = devices.first(where: { device in
            device.responds(to: NSSelectorFromString("deviceName")) &&
            (device.value(forKey: "deviceName") as? String)?.precomposedStringWithCanonicalMapping == name.precomposedStringWithCanonicalMapping
        }) else { return }
        requested = true
        request(device, selectorIndex: 0)
    }

    private func request(_ device: NSObject, selectorIndex: Int) {
        guard !finished, let session else { return }
        let names = ["enableRemoteHotspotForDevice:withCompletionHandler:", "enableHotspotForDevice:withCompletionHandler:"]
        guard selectorIndex < names.count else { finish(nil); return }
        let selector = NSSelectorFromString(names[selectorIndex])
        guard session.responds(to: selector) else { request(device, selectorIndex: selectorIndex + 1); return }
        callback = { [weak self] info, result in
            DispatchQueue.main.async {
                guard let self else { return }
                if let name = info as? String, let password = result as? String, !name.isEmpty, !password.isEmpty {
                    self.finish((name, password)); return
                }
                guard let object = info as? NSObject,
                      object.responds(to: NSSelectorFromString("name")), object.responds(to: NSSelectorFromString("password")),
                      let name = object.value(forKey: "name") as? String,
                      let password = object.value(forKey: "password") as? String,
                      !name.isEmpty, !password.isEmpty else { self.request(device, selectorIndex: selectorIndex + 1); return }
                self.finish((name, password))
            }
        }
        guard let callback else { finish(nil); return }
        _ = session.perform(selector, with: device, with: callback as AnyObject)
    }
}
