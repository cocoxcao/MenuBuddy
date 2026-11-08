#!/bin/bash
# Install or update MenuBuddy:
#   curl -fsSL https://raw.githubusercontent.com/cocoxcao/MenuBuddy/main/install.sh | bash
# Build it from the code instead (needs Apple's Command Line Tools):
#   curl -fsSL https://raw.githubusercontent.com/cocoxcao/MenuBuddy/main/install.sh | bash -s -- --from-source
# Delete it (the app, its settings and its Accessibility entry):
#   curl -fsSL https://raw.githubusercontent.com/cocoxcao/MenuBuddy/main/install.sh | bash -s -- --uninstall
#
# It downloads the latest release from GitHub, checks the zip against the release's SHA-256 file and
# the app's code signature, quits a running MenuBuddy, puts MenuBuddy.app in /Applications (or
# ~/Applications when /Applications isn't writable) and opens it. Nothing else is installed or changed.
set -euo pipefail

REPO=cocoxcao/MenuBuddy
BASE=${MENUBUDDY_BASE:-https://github.com/$REPO/releases/latest/download}
# Tests: MENUBUDDY_BASE=file://… (a local release), MENUBUDDY_DEST=<folder>, MENUBUDDY_TEST=1 (never
# quits or opens an app).

say() { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf 'MenuBuddy install: %s\n' "$*" >&2; exit 1; }

quit_running() {
    if [[ ${MENUBUDDY_TEST:-} != 1 ]] && pgrep -x MenuBuddy >/dev/null; then
        say "Quitting the running MenuBuddy…"
        osascript -e 'quit app "MenuBuddy"' >/dev/null 2>&1 || pkill -x MenuBuddy || true
        sleep 1
    fi
}

uninstall() {
    quit_running
    local d found=0
    for d in ${MENUBUDDY_DEST:-/Applications "$HOME/Applications"}; do
        if [[ -d $d/MenuBuddy.app ]]; then
            rm -rf "$d/MenuBuddy.app" || fail "couldn't delete $d/MenuBuddy.app (try dragging it to the Trash)."
            say "Deleted $d/MenuBuddy.app"; found=1
        fi
    done
    (( found )) || say "MenuBuddy.app wasn't in Applications."
    if [[ ${MENUBUDDY_TEST:-} != 1 ]]; then
        defaults delete com.cocoxcao.menubuddy >/dev/null 2>&1 && say "Forgot its settings" || true
        tccutil reset Accessibility com.cocoxcao.menubuddy >/dev/null 2>&1 && say "Removed it from the Accessibility list" || true
    fi
    say "MenuBuddy is gone. Thanks for trying it!"
}

main() {   # everything runs from here, so a half-downloaded script does nothing
    [[ $(uname -s) == Darwin ]] || fail "MenuBuddy is a Mac app."
    if [[ ${1:-} == --uninstall ]]; then uninstall; return; fi
    local major; major=$(sw_vers -productVersion | cut -d. -f1)
    (( major >= 13 )) || fail "MenuBuddy needs macOS 13 or later (this Mac has $(sw_vers -productVersion))."

    tmp=$(mktemp -d)   # global: the EXIT trap runs after main returns
    trap 'rm -rf "${tmp:-}"' EXIT

    if [[ ${1:-} == --from-source ]]; then
        xcode-select -p >/dev/null 2>&1 || fail "building needs the Command Line Tools: run  xcode-select --install  then try again."
        say "Downloading the code…"
        git clone --quiet --depth 1 "https://github.com/$REPO.git" "$tmp/src"
        say "Building (a minute or two)…"
        "$tmp/src/scripts/build.sh" --release >/dev/null
        ditto -x -k "$tmp/src/build/MenuBuddy.zip" "$tmp/app"
    else
        say "Downloading MenuBuddy…"
        curl -fsSL "$BASE/MenuBuddy.zip" -o "$tmp/MenuBuddy.zip" || fail "couldn't download $BASE/MenuBuddy.zip"
        curl -fsSL "$BASE/MenuBuddy.zip.sha256" -o "$tmp/sum" || fail "couldn't download the checksum file"
        local want got
        want=$(awk '{print $1; exit}' "$tmp/sum")
        got=$(shasum -a 256 "$tmp/MenuBuddy.zip" | awk '{print $1}')
        [[ -n $want && $want == "$got" ]] || fail "the download doesn't match its checksum; nothing was installed."
        say "Checksum OK ($got)"
        ditto -x -k "$tmp/MenuBuddy.zip" "$tmp/app"
    fi

    local app=$tmp/app/MenuBuddy.app
    [[ -d $app ]] || fail "the download has no MenuBuddy.app."
    codesign --verify --deep --strict "$app" 2>/dev/null || fail "the app's code signature doesn't check out; nothing was installed."

    # Update the copy that's already there (Applications or ~/Applications), else /Applications.
    local dest=${MENUBUDDY_DEST:-}
    if [[ -z $dest ]]; then
        if [[ -d /Applications/MenuBuddy.app ]]; then dest=/Applications
        elif [[ -d $HOME/Applications/MenuBuddy.app ]]; then dest=$HOME/Applications
        else dest=/Applications; fi
    fi
    if [[ ! -w $dest ]]; then dest=$HOME/Applications; mkdir -p "$dest"; fi

    quit_running
    rm -rf "$dest/MenuBuddy.app"
    ditto "$app" "$dest/MenuBuddy.app"
    say "Installed $dest/MenuBuddy.app ($(defaults read "$dest/MenuBuddy.app/Contents/Info" CFBundleShortVersionString))"

    [[ ${MENUBUDDY_TEST:-} == 1 ]] || open "$dest/MenuBuddy.app"
    echo "MenuBuddy needs Accessibility access to click other apps' menu bar icons:"
    echo "right-click its menu bar icon → Allow Accessibility Access…"
    echo "(After an update, turn MenuBuddy's switch off and on again in that list.)"
}

main "$@"
