# Third-party and platform notices

The MIT grant in LICENSE applies to original Caffeine contributions. Apple system frameworks are platform dependencies, not vendored code.

`Sources/CGVirtualDisplay.h` declares an undocumented Apple interface. Its existing comment references DeskPad and Chromium, but the exact derivation and applicable attribution of this particular header have not been established. It has been left unchanged for provenance review; the original-code MIT grant does not purport to relicense unidentified third-party material. Public release review must resolve this item first.

Primary references for that review:
- https://github.com/Stengo/DeskPad/blob/main/DeskPad/CGVirtualDisplayPrivate.h
- https://github.com/Stengo/DeskPad/blob/main/LICENSE.md (MIT)
- https://chromium.googlesource.com/chromium/src/+/HEAD/ui/display/mac/test/virtual_display_util_mac.mm
- https://chromium.googlesource.com/chromium/src/+/HEAD/LICENSE (BSD-style)

The Caffeine app icon is AI-edited artwork based on the user-supplied coffee cup, with a charcoal background for contrast, stored in Resources/AppIcon.png. make-icon.swift produces its macOS size representations; it embeds no SF Symbol. System-provided symbols are used only in the app interface. README screenshots show the app menus.
