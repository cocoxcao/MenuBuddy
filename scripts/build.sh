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
# Ad-hoc signing normally pins the designated requirement to this build's hash, so macOS forgets
# the Accessibility permission after every rebuild (the switch still shows on, but it no longer
# applies). Pinning the requirement to the bundle id keeps the permission across rebuilds.
#
# A build you hand to other people keeps the default requirement (this build's hash) and the
# hardened runtime instead: with the bundle-id requirement, any ad-hoc app that claims the same
# bundle id would inherit their Accessibility grant. They re-allow Accessibility after an update.
if [[ "${1:-}" == "--release" ]]; then
    codesign --force --sign - --options runtime "$APP"
    rm -f build/MenuBuddy.zip
    ditto -c -k --sequesterRsrc --keepParent "$APP" build/MenuBuddy.zip
    (cd build && shasum -a 256 MenuBuddy.zip > MenuBuddy.zip.sha256)   # install.sh checks the download against it
    echo "Zipped build/MenuBuddy.zip ($(lipo -archs "$APP/Contents/MacOS/MenuBuddy"))"
    exit 0
fi
codesign --force --sign - -r='designated => identifier "com.cocoxcao.menubuddy"' "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x MenuBuddy 2>/dev/null || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/MenuBuddy.app
    cp -R "$APP" ~/Applications/
    open ~/Applications/MenuBuddy.app
    echo "Installed and launched ~/Applications/MenuBuddy.app"
fi
