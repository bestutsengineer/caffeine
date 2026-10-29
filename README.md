# Caffeine

A standalone macOS menu bar utility that keeps a MacBook awake with the lid closed.

The menu has a Keep Awake switch, a power/temperature summary, Options, and Diagnostics. Options contains battery operation, a configurable battery cutoff, the optional virtual display, and Start at Login. Detailed lid tests and logs stay in Diagnostics.

## Sleep protection

Keep Awake sets `pmset -a disablesleep 1` and holds an idle-sleep assertion. This kernel setting also bypasses macOS's low-battery sleep, so Caffeine checks lid, power, battery and temperature every five seconds:

- Battery operation is opt-in. Otherwise closing the lid on battery pauses Keep Awake.
- At or below the configured battery cutoff, Keep Awake pauses on battery. The default is 20%; choose 5–80% in Options → Battery Cutoff or through the CLI.
- Critical temperature or unavailable lid/power/thermal sensors pauses Keep Awake. A missing battery reading on battery also pauses it.
- Protection resumes when the condition clears. Off, Quit, logout and SIGTERM restore normal sleep.

The battery cutoff leaves a reserve; a low value allows less time for the machine to sleep safely. Polling takes up to about five seconds to notice a power or temperature change. Do not keep a running laptop in a bag.

## Optional virtual display

This experimental feature is off by default for new installations; existing enabled/disabled preferences, including the older implicit-on default, are preserved on upgrade. Leave it off for ordinary computer use. Options → Headless Virtual Display → When to Use This explains it on demand.

When explicitly enabled, Caffeine creates a temporary 1920×1080 desktop only while keep-awake protection is active, the lid is known to be closed, the built-in display is inactive, and no external display is online. A sleeping external monitor still counts as connected. Unknown display enumeration suppresses creation. A short settling interval prevents transient lid/hotplug states from creating a desktop. If private-display setup immediately reactivates the built-in screen, Caffeine suspends further attempts until the lid opens or the feature/protection is toggled, avoiding a desktop creation/removal loop. The reason appears in Diagnostics and the log.

Display-configuration and screen-wake notifications reconcile promptly; the five-second sensor loop is a fallback. Caffeine removes its display when the lid opens, a monitor connects, the built-in screen becomes active, the option is disabled, protection pauses, or the app exits. It does not directly change resolution, mirroring, display arrangement, or display/lock timeouts. macOS can move windows when any desktop is added or removed, so zero disruption cannot be promised when the option is enabled.

The feature uses private CGVirtualDisplay API, which can change between macOS releases. This display belongs to the process; updates can briefly interrupt headless capture, and it does not run before login or bypass screen locking/capture permissions.

## Build

Requires macOS 14 or later and Xcode command line tools. Apple silicon and Intel builds target the current machine.

```sh
./build.sh
build/Caffeine.app/Contents/MacOS/Caffeine --selftest
```

`--selftest` runs deterministic guard/parser/settings/tracker checks without changing system power settings. Add `--sensors` for read-only hardware checks. `--selftest --live` changes sleep settings and refuses to run while Caffeine is running or the lid is not known to be open.

`./build.sh --install` installs to `~/Applications/Caffeine.app` only while Caffeine is stopped. It refuses to stop an active app because doing so could immediately sleep a closed MacBook. Preserve the running version until a guarded deployment can maintain the sleep setting, verify the new process, and roll back on failure. `--handoff` is reserved for that guarded update path; it exits without clearing SleepDisabled, so it must be followed by a verified replacement or a bounded watchdog that restores normal sleep. Quit normally for all other cases.

## Permission

`/etc/sudoers.d/caffeine` permits only `pmset -a disablesleep 0` and `pmset -a disablesleep 1` without a password. `Caffeine --permission-command` prints the one-time setup command. Remove the rule with `sudo rm /etc/sudoers.d/caffeine`.

## CLI

Use `~/Applications/Caffeine.app/Contents/MacOS/Caffeine`:

```text
--status | --on | --off | --refresh | --quit
--set virtualDisplay=0|1
--set allowOnBattery=0|1
--set startAtLogin=0|1
--set minBatteryPercent=5..80
--selftest [--sensors] [--live]
--test-virtual-display
```

`--test-virtual-display` briefly creates a real display and should be used only when a display interruption is acceptable. `--sim` fake sensor readings require a debug launch with `CAFFEINE_DEBUG=1`.

## Files and recovery

- Settings: `~/Library/Preferences/local.caffeine.plist` (existing settings are preserved).
- Published diagnostics: `~/Library/Application Support/Caffeine/state.json`.
- Rotating JSON event log: `~/Library/Logs/Caffeine/events.log`.
- Optional login/crash-restart job: `~/Library/LaunchAgents/local.caffeine.agent.plist`.

A crash can leave SleepDisabled set until launchd restarts the app. Keep Start at Login enabled for crash recovery. A force kill is not a normal Quit. To restore normal sleep manually: `sudo pmset -a disablesleep 0`.

## Before login

The optional `prelogin-guard/` system job checks every 30 seconds while no user is logged in. It enables Keep Awake only when the saved setting is on, AC power is available, the battery exceeds the saved cutoff and no thermal warning is reported. Unknown preferences or sensor failures restore normal sleep. Its local root-owned configuration `/Library/Preferences/local.caffeine.prelogin.plist` must contain a `PreferencesPath` string pointing to the chosen account's `Library/Preferences/local.caffeine.plist`. An absent or invalid path fails closed to normal sleep. Keep this machine-specific configuration outside the repository. Battery operation remains disabled before login.

The user app cannot run at the FileVault unlock screen. No live restart or sleep test is performed by the build process.

## Screen off, lock and system sleep

Keep Awake prevents system sleep while its guards allow it. macOS can still turn displays off and lock the screen on its normal schedule. Apps normally continue running when locked, although individual apps and capture tools may pause, require authentication or deny access to protected data. Screen locking is not logout, nor does it re-lock a mounted FileVault volume. On Apple silicon Macs, Data Protection follows login/logout boundaries rather than the lock/unlock boundary used by iPhone and iPad; locking is not a blanket promise that every file becomes inaccessible to already-running apps. Caffeine neither changes nor bypasses these protections.

The main menu stays focused on current power state. Options → Sleep, Lock & Security explains the distinction only when opened, with buttons for the native Lock Screen settings page and [Apple's Data Protection classes guide](https://support.apple.com/guide/security/secb010e978a/web). Options → Lock Screen Settings also opens that pane directly. Caffeine does not change display timeout, password requirements or locking policy.

Event logs distinguish system sleep/wake, screen sleep/wake, session activity and best-effort lock/unlock notifications. Session activation is not treated as proof of unlocking. Unknown notification state stays unknown until an event is observed. Launch records include version, source revision, executable SHA-256, PID and a per-run ID; every event includes its run ID, timestamp, monotonic uptime and power/guard/configuration/display context. Owned virtual-display objects are recorded separately from actual active and online displays.

Power/lid/thermal/configuration/display changes produce transition events; unchanged five-second samples do not. Minute heartbeats while the lid is closed establish continued execution. A long wall/monotonic timer gap is evidence for investigation, not proof of sleep. After wake or a lid session, bounded `power_log_evidence` records capture the scoped `pmset` sleep/display reasons and timestamps on a background queue. A failed power-log read is reported explicitly. Logs can establish the events observed by the app; they cannot retrospectively recover notifications from a version that did not record them.

## License and public-source preparation

Original Caffeine contributions are offered under MIT (see LICENSE). `NOTICE.md` records an unresolved provenance review for the unchanged private-API declarations header; resolve it before calling the release fully cleared. No compiled daemon, user diagnostics, operational notes or local configuration is part of the source export.

## Contributor checks

Install scanners with `brew install gitleaks trufflehog` and enable the staged hook with `git config core.hooksPath .githooks`. The `.env.example` file is documentation only; no credentials or dotenv runtime configuration are required. Use a GitHub no-reply address or an intentional project identity for public commits.

Before publishing, scan both the source tree and every Git ref; the staged hook alone does not cover old commits. Do not ship `build/`, diagnostics, session notes, machine-specific configuration or Git history containing private data. This snapshot includes no CI workflow and does not grant Actions permissions.

## Menu gestures and macOS timing

Double-click the menu bar cup to toggle Keep Awake. Single-click opens the menu after macOS's double-click interval; right-click opens it immediately. Disable the gesture in Options → Double-Click Icon to Toggle Keep Awake, or use `--set doubleClickToToggle=0`. The icon tooltip also explains the current gesture.

Options → macOS Sleep & Lock shows the current power source's configured idle-system-sleep timeout when Caffeine is off, display timeout, screen saver delay and password requirement. These are settings, not a countdown or guarantee: lid closing, manual sleep, other assertions and app behavior can change actual timing. Values refresh in the background; unavailable policies are shown explicitly. The password delay is measured after the screen saver starts or displays turn off, rather than after Caffeine is disabled. Detailed FileVault/data-protection context stays in Options → Sleep, Lock & Security.
