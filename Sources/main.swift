import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
if let first = arguments.first, first.hasPrefix("--") || first == "-h" {
    exit(CLI.run(arguments))
}

// One instance at a time. The login item's instance takes over from a manually opened one.
let bundleID = Bundle.main.bundleIdentifier ?? "local.caffeine"
let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .filter { $0.processIdentifier != getpid() }
if !others.isEmpty {
    guard LoginItem.launchedByAgent else { exit(0) }
    DistributedNotificationCenter.default().postNotificationName(AppController.command, object: "handoff",
                                                                 userInfo: nil, deliverImmediately: true)
    let deadline = Date().addingTimeInterval(5)
    while others.contains(where: { !$0.isTerminated }) && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
} else if LoginItem.isEnabled && !LoginItem.launchedByAgent && LoginItem.kickstart() {
    // Opened by hand while Start at Login is on: let launchd run it so a crash gets relaunched.
    exit(0)
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
