import Foundation

/// Pure eligibility rules: creating a desktop must never depend on a sleeping monitor
/// looking inactive. The virtual display is only for an explicitly enabled headless session.
enum VirtualDisplayEligibility: String, Equatable {
    case disabled, protectionInactive, lidUnknown, lidOpen, displayInformationUnavailable
    case externalMonitorConnected, builtinDisplayActive, headless

    var shouldExist: Bool { self == .headless }
}

enum VirtualDisplayPolicy {
    static let settleSeconds: TimeInterval = 2

    /// If creating the private display immediately wakes a real screen, stop retrying
    /// during this lid-closed session rather than repeatedly rearranging the desktop.
    static func shouldPauseForSession(eligibility: VirtualDisplayEligibility, secondsSinceCreation: TimeInterval?) -> Bool {
        guard eligibility == .builtinDisplayActive, let age = secondsSinceCreation else { return false }
        return age >= 0 && age <= 10
    }

    static func evaluate(enabled: Bool, protectionActive: Bool, lidClosed: Bool?,
                         displays: DisplayState) -> VirtualDisplayEligibility {
        guard enabled else { return .disabled }
        guard protectionActive else { return .protectionInactive }
        guard let lidClosed else { return .lidUnknown }
        guard lidClosed else { return .lidOpen }
        guard displays.activeReadStatus == 0, displays.onlineReadStatus == 0,
              let externalOnline = displays.externalOnline else { return .displayInformationUnavailable }
        guard externalOnline == 0 else { return .externalMonitorConnected }
        guard !displays.builtinActive else { return .builtinDisplayActive }
        return .headless
    }
}

/// Shared, on-demand explanation. Keep the normal menu focused on the current power state.
enum CaffeineHelp {
    static let securityTitle = "Sleep, Lock & Security"
    static let securityText = """
        Keep Awake controls system sleep. macOS can still turn displays off and lock the screen.

        Locking protects access to your session. It does not log you out or re-lock your mounted FileVault volume. On Apple silicon Macs, Data Protection follows login/logout boundaries; locking is not a blanket promise that every file becomes inaccessible to running apps.

        Apps normally continue, but an app can pause screen capture, require authentication or deny access to protected data. Caffeine neither changes nor bypasses those protections. Logout, restart and app-specific data protection have different effects.
        """
    static let appleSecurityURL = URL(string: "https://support.apple.com/guide/security/secb010e978a/web")!
    static let virtualDisplayTitle = "Headless Virtual Display"
    static let virtualDisplayText = """
        Optional and off by default for new installations. Existing preferences are preserved. Enable only when a headless app needs a screen while the lid is closed.

        Caffeine creates a temporary 1920×1080 display only while Keep Awake is active, the built-in display is inactive and no external monitor is connected, including sleeping monitors. It removes the display when the lid opens, a monitor connects, Keep Awake pauses or this option is disabled. It does not change your display arrangement, resolution or mirroring settings directly.

        Adding or removing any display can cause macOS to move windows. This feature uses a private macOS API and cannot guarantee compatibility with every app or macOS update. It does not prevent display power-off, unlock the screen or bypass capture permissions. Leave it off for ordinary computer use.
        """
}
