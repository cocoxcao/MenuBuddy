#!/bin/bash
# Build MenuBuddy.app with the Xcode Command Line Tools (full Xcode not needed).
#   scripts/build.sh            → build/MenuBuddy.app
#   scripts/build.sh --install  → also copy to ~/Applications and launch it
#   scripts/build.sh --release  → universal (Apple silicon + Intel) build zipped to build/MenuBuddy.zip,
#                                 for sharing (see the signing note below)
#
# Uses swiftc directly because SwiftPM's manifest step fails on Command Line Tools 16.4.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build

flags=(-O -swift-version 5)

# Command Line Tools 16.4 ships two modulemaps that both define SwiftBridging, which breaks every
# AppKit import. When that's the case, hide the duplicate with a VFS overlay (system files untouched).
CLT_SWIFT=/Library/Developer/CommandLineTools/usr/include/swift
if [[ -f $CLT_SWIFT/module.modulemap && -f $CLT_SWIFT/bridging.modulemap ]] \
   && grep -q "module SwiftBridging" "$CLT_SWIFT/module.modulemap"; then
    sed "s|@EMPTY@|$PWD/scripts/clt-fix/empty.modulemap|" scripts/clt-fix/overlay.yaml.in > build/overlay.yaml
    flags+=(-vfsoverlay build/overlay.yaml -Xcc -ivfsoverlay -Xcc build/overlay.yaml)
fi

# Development builds keep the dev tools (MENUBUDDY_THEMES, --snapshot, --seasonal-test); release builds
# compile them out.
if [[ "${1:-}" != "--release" ]]; then flags+=(-D DEV_BUILD); fi

if [[ "${1:-}" == "--release" ]]; then
    for arch in arm64 x86_64; do
        swiftc "${flags[@]}" -target "$arch-apple-macos13.0" -o "build/MenuBuddy-$arch" Sources/MenuBuddy/*.swift
    done
    lipo -create -output build/MenuBuddy build/MenuBuddy-arm64 build/MenuBuddy-x86_64
else
    swiftc "${flags[@]}" -target "$(uname -m)-apple-macos13.0" -o build/MenuBuddy Sources/MenuBuddy/*.swift
fi

if [[ ! -f Resources/AppIcon.icns ]]; then
    swiftc "${flags[@]}" -target "$(uname -m)-apple-macos13.0" -o build/make-icon scripts/make-icon.swift
    build/make-icon Resources/AppIcon.icns
fi

APP=build/MenuBuddy.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/MenuBuddy "$APP/Contents/MacOS/MenuBuddy"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/Themes "$APP/Contents/Resources/Themes"
# Signed with "Call Notes Local Signing" (Coco's private certificate, made by call-notes/build.sh
# --make-signing) when this Mac has it. Then the requirement is the bundle id AND that certificate:
# macOS keeps Accessibility / Automation across updates, and only builds signed with her private
# key match. Without it the build is signed ad hoc (tied to this exact build; a new build asks
# again). Never pin the bundle id alone: any program could claim it and borrow the permissions.
SIGNING="Call Notes Local Signing"
IDENTITY="$(security find-certificate -c "$SIGNING" -Z ~/Library/Keychains/login.keychain-db 2>/dev/null | awk '/SHA-1/ {print $3; exit}')"
if [[ "${1:-}" == "--release" && -z $IDENTITY ]]; then echo "No \"$SIGNING\" on this Mac: releases must be signed with it." >&2; exit 1; fi
codesign --force --sign "${IDENTITY:--}" --timestamp=none --options runtime "$APP"
[[ -n $IDENTITY ]] && echo "Signed with \"$SIGNING\"" || echo "Signed ad hoc"
if [[ "${1:-}" == "--release" ]]; then
    rm -f build/MenuBuddy.zip
    ditto -c -k --sequesterRsrc --keepParent "$APP" build/MenuBuddy.zip
    (cd build && shasum -a 256 MenuBuddy.zip > MenuBuddy.zip.sha256)   # install.sh checks the download against it
    echo "Zipped build/MenuBuddy.zip ($(lipo -archs "$APP/Contents/MacOS/MenuBuddy"))"
    exit 0
fi
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x MenuBuddy 2>/dev/null || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/MenuBuddy.app
    cp -R "$APP" ~/Applications/
    open ~/Applications/MenuBuddy.app
    echo "Installed and launched ~/Applications/MenuBuddy.app"
fi
