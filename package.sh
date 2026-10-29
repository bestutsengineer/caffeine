#!/bin/bash
# Creates an unsigned universal installer; does not install or launch anything.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh --universal
build/Caffeine.app/Contents/MacOS/Caffeine --selftest
codesign --verify --deep --strict build/Caffeine.app
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/caffeine-package.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/root/Applications" "$STAGING/scripts"
ditto --norsrc --noextattr build/Caffeine.app "$STAGING/root/Applications/Caffeine.app"
cp packaging/preinstall "$STAGING/scripts/preinstall"
pkgbuild --analyze --root "$STAGING/root" "$STAGING/components.plist"
/usr/libexec/PlistBuddy -c 'Set :0:BundleIsRelocatable false' "$STAGING/components.plist"
/usr/libexec/PlistBuddy -c 'Set :0:BundleOverwriteAction upgrade' "$STAGING/components.plist"
pkgbuild --root "$STAGING/root" --component-plist "$STAGING/components.plist" \
    --scripts "$STAGING/scripts" --identifier local.caffeine.installer \
    --version "$VERSION" --install-location / --ownership recommended "$STAGING/component.pkg"
cat > "$STAGING/distribution.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>Caffeine</title>
  <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
  <allowed-os-versions><os-version min="14.0"/></allowed-os-versions>
  <domains enable_localSystem="true" enable_currentUserHome="false" enable_anywhere="false"/>
  <choices-outline><line choice="default"/></choices-outline>
  <choice id="default" visible="false"><pkg-ref id="local.caffeine.installer"/></choice>
  <pkg-ref id="local.caffeine.installer">component.pkg</pkg-ref>
</installer-gui-script>
XML
productbuild --distribution "$STAGING/distribution.xml" --package-path "$STAGING" "build/Caffeine-${VERSION}-universal.pkg"
echo "Created build/Caffeine-${VERSION}-universal.pkg (unsigned; not notarized)"
