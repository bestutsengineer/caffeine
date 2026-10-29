#!/bin/bash
# Builds Caffeine.app into ./build. Pass --install to copy it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Caffeine.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
    -module-cache-path build/module-cache \
    -import-objc-header Sources/CGVirtualDisplay.h \
    -framework AppKit -framework IOKit -framework CoreGraphics \
    Sources/*.swift -o "$APP/Contents/MacOS/Caffeine"

cp Info.plist "$APP/Contents/Info.plist"
REVISION=unknown
if git rev-parse --is-inside-work-tree >/dev/null 2>&1 && [ "$(git rev-parse --show-toplevel)" = "$(pwd -P)" ]; then
    REVISION=$(git rev-parse --short=12 HEAD)
    if [ -n "$(git status --porcelain -- Sources Info.plist build.sh)" ]; then REVISION="$REVISION-dirty"; fi
fi
/usr/libexec/PlistBuddy -c "Add :CaffeineSourceRevision string $REVISION" "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    DEST="$HOME/Applications/Caffeine.app"
    if pgrep -x Caffeine >/dev/null; then
        echo "Caffeine is running. Use a guarded deployment; stopping it may sleep a closed MacBook." >&2
        exit 1
    fi
    BACKUP="$HOME/Applications/Caffeine.previous.app"
    STAGED="$HOME/Applications/Caffeine.next.app"
    rm -rf "$STAGED"
    cp -R "$APP" "$STAGED"
    codesign --verify --deep --strict "$STAGED"
    if [ -e "$DEST" ]; then
        rm -rf "$BACKUP"
        mv "$DEST" "$BACKUP"
    fi
    if ! mv "$STAGED" "$DEST"; then
        [ ! -e "$BACKUP" ] || mv "$BACKUP" "$DEST"
        exit 1
    fi
    echo "Installed $DEST (previous app retained at $BACKUP)"
fi
