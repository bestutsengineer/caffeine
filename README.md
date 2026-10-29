# Caffeine

**Keep your Mac awake—even with the lid closed.** Caffeine is a small macOS menu-bar app for long downloads, background tasks and other work that needs to keep running.

<img src="docs/images/menu.png" alt="Caffeine menu showing Keep Awake enabled, battery status, Options and Diagnostics" width="540">

<img src="docs/images/options.png" alt="Caffeine Options with battery cutoff, virtual display, double-click gesture and sleep and lock settings" width="540">

*Screenshots show a custom 10% cutoff. New installations default to 15%.*

Requires **macOS 14 or later**. It lives in the menu bar, with no Dock icon. This repository provides source code; see [For Developers](#for-developers) to build and install it. No downloadable installer is currently published.

## How to use

1. Open **Caffeine** from Applications and click the cup in the menu bar.
2. Turn on **Keep Awake with Lid Closed**. If **Set Up Permission…** appears, open it, copy the setup command, then paste it into Terminal and enter your administrator password. This is a one-time setup.
3. Check the status before closing the lid. A **filled cup** means Caffeine is keeping your Mac awake; an **outline cup** means it is off. A **warning triangle** means protection is paused—open the menu for the reason.
4. Turn Keep Awake off, or choose **Quit**, to restore normal sleep.

**Shortcut:** double-click the cup to toggle Keep Awake. Single-click opens the menu below the cup after a short delay; right-click opens it immediately. You can disable double-click toggling in **Options**.

## Useful options

- **Allow on Battery:** on by default for new installations; your saved choice is preserved on upgrade. Turn it off to pause protection when you close the lid without a charger. **Battery Cutoff** pauses protection at your chosen percentage; the default is 15%, adjustable from 5–80%.
- **Start at Login:** opens Caffeine when you sign in and helps it recover after a crash.
- **macOS Sleep & Lock:** shows your configured sleep, display and password delays. These are settings, not live countdowns. **Lock Screen Settings…** opens the corresponding system settings.
- **Headless Virtual Display:** leave this off for ordinary use. Enable it only if a screen-sharing or capture app needs a desktop while the lid is closed and no external monitor is connected. It is experimental and may move windows when the temporary display appears or disappears.

## Sleep and screen locking

Caffeine keeps the **computer** awake. The display can still turn off, and macOS can still lock the screen. Apps normally keep running while locked, but some apps or screen-sharing tools may pause or ask you to sign in again.

Caffeine does not change your password or locking settings. For more detail, open **Options → Sleep, Lock & Security…**.

Protection pauses for low battery, critical temperature or unavailable required sensors, and resumes when the condition clears. Checks run about every five seconds. Keep the Mac ventilated; do not put it in a bag while it is running. **Diagnostics** provides status and logs if something seems wrong.

## For Developers

### Build and install

Requires Xcode Command Line Tools. Normal builds target the current Mac's architecture; `./build.sh --universal` builds for Apple silicon and Intel. `./package.sh` builds, runs self-tests and produces `build/Caffeine-<version>-universal.pkg`. The installer does not configure the sleep permission, install the optional prelogin job or launch the app. Distribution packages currently have no Developer ID signature or notarization.

```sh
git clone https://github.com/bestutsengineer/caffeine.git
cd caffeine
./build.sh
build/Caffeine.app/Contents/MacOS/Caffeine --selftest
./build.sh --install
open ~/Applications/Caffeine.app
```

Installation refuses to replace a running Caffeine. Quit normally with the lid open before updating. `--selftest` does not change power settings; `--sensors` adds read-only hardware checks. `--selftest --live` changes sleep settings and requires Caffeine to be stopped and the lid open.

### Power control and recovery

Caffeine holds an idle-sleep assertion and sets `pmset -a disablesleep 1`. This setting also bypasses macOS's low-battery sleep, so battery and thermal guards are essential. Normal Off, Quit, logout and SIGTERM restore sleep; a crash or force kill can leave it disabled until the app restarts.

To restore sleep manually:

```sh
sudo pmset -a disablesleep 0
```

The one-time setup grants only the two sleep-toggle commands through `/etc/sudoers.d/caffeine`. Print the setup command with `Caffeine --permission-command`; revoke it with `sudo rm /etc/sudoers.d/caffeine`. `--handoff` is reserved for guarded updates with a verified replacement and bounded rollback.

### CLI and local files

Run `~/Applications/Caffeine.app/Contents/MacOS/Caffeine` with:

```text
--status | --on | --off | --refresh | --quit
--set allowOnBattery=0|1
--set minBatteryPercent=5..80
--set doubleClickToToggle=0|1
--set virtualDisplay=0|1
--set startAtLogin=0|1
```

Settings: `~/Library/Preferences/local.caffeine.plist`. Status: `~/Library/Application Support/Caffeine/state.json`. Rotating logs: `~/Library/Logs/Caffeine/events.log`. Logs distinguish system sleep, display sleep and observed lock events; they cannot prove events they did not record.

The virtual display uses private `CGVirtualDisplay` API. It is removed when the lid opens, a real display becomes available or protection stops. Existing preferences are preserved on upgrade. `--test-virtual-display` briefly creates a real display; debug sensor simulation requires `CAFFEINE_DEBUG=1`.

The optional `prelogin-guard/` job needs a root-owned `/Library/Preferences/local.caffeine.prelogin.plist` with `PreferencesPath` pointing to the chosen user's preferences. It allows AC operation only and restores normal sleep if required data is unavailable. The app cannot run at the FileVault unlock screen.

### Contributing and license

Install scanners with `brew install gitleaks trufflehog`, then enable the staged secret check:

```sh
git config core.hooksPath .githooks
```

Scan the working tree and all Git refs before publishing. Keep credentials, personal configuration, builds and diagnostics out of commits. `.env.example` is documentation only; no credentials are required.

Original contributions are licensed under [MIT](LICENSE). [NOTICE.md](NOTICE.md) discloses unresolved attribution for the private-API declarations header; that material is not automatically covered by the original-code license. See [SECURITY.md](SECURITY.md) for security reporting.
