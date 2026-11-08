# For AI assistants

Steps for installing, updating, building or removing MenuBuddy on the user's Mac. MenuBuddy is a
macOS menu bar app (macOS 13 or later, Apple silicon or Intel). Ask before anything the user didn't
request, and tell them what you ran.

## Install or update

1. Read `install.sh` in this repo first (it's short) and tell the user in one line what it does.
2. Run it:
   ```sh
   curl -fsSL https://raw.githubusercontent.com/cocoxcao/MenuBuddy/main/install.sh | bash
   ```
   It downloads the latest GitHub release, checks `MenuBuddy.zip` against `MenuBuddy.zip.sha256`
   and the app's code signature, quits a running MenuBuddy, installs to `/Applications` (or
   `~/Applications`) and opens it. It stops without installing anything if a check fails.
3. Check: `ls -d /Applications/MenuBuddy.app ~/Applications/MenuBuddy.app 2>/dev/null` and
   `pgrep -x MenuBuddy`.
4. Tell the user the one step only they can do: MenuBuddy needs **Accessibility** access to click
   other apps' menu bar icons. Right-click its menu bar icon → Allow Accessibility Access…, then turn
   MenuBuddy on in System Settings → Privacy & Security → Accessibility. (After an update: switch it
   off and on again.)

## Build from the code instead

Needs Apple's Command Line Tools (`xcode-select -p`; if missing, the user runs
`xcode-select --install`). Either end the install line with `bash -s -- --from-source`, or:

```sh
git clone https://github.com/cocoxcao/MenuBuddy.git && cd MenuBuddy
scripts/build.sh --install   # builds build/MenuBuddy.app, copies it to ~/Applications and opens it
```

## Remove

```sh
curl -fsSL https://raw.githubusercontent.com/cocoxcao/MenuBuddy/main/install.sh | bash -s -- --uninstall
```

Quits MenuBuddy, deletes the app from `/Applications` and `~/Applications`, deletes its settings
(`defaults delete com.cocoxcao.menubuddy`) and resets its Accessibility entry.

## Don't

- Don't use `sudo`; nothing here needs it.
- Don't turn off Gatekeeper or change system security settings.
- MenuBuddy makes no network requests (except Check for Updates…, only when the user clicks it) and
  needs no accounts or keys.
