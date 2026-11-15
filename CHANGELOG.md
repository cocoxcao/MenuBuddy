# Changelog

Older versions: see the GitHub releases.

## 0.3.6 — 2026-11-15
- Fixed the rest of the memory leak, the bigger part: while the drop-down was closed, MenuBuddy rebuilt its page every 30 seconds, and each rebuild kept about 0.4 MB (about 1 GB a day). The cause: the list of your menu bar apps was written out with its fields in a different order each time, so the same list looked new. The list is now written the same way every time, and the page rebuilds only when your apps really change.

## 0.3.5 — 2026-11-14
- Fixed a memory leak: the drop-down's web page grew about 0.5 MB each time it opened, and never gave it back (2.2 GB after two days). The page is now built only when your menu bar apps change; an open replays its animations. After 300 opens it gives the memory back within seconds, in every theme.

## 0.3.4 — 2026-11-12
- Safer updates: the install script accepts only an app signed with the author's own certificate, and Check for Updates uses the exact release it offers.

## 0.3.3 — 2026-11-11
- Fix: the pill icon in the menu bar is no longer cut off at the sides.

## 0.3.2 — 2026-11-11
- New icon: a pill with rings spreading from its top-right corner. It is the menu bar icon (dark pill, white rings, the same on every menu bar) and, on the black tile, the app icon. Themes still change the panel's look.

## 0.3.1 — 2026-11-11
- Signed with Coco's own certificate, so macOS keeps MenuBuddy's permissions (Accessibility) after updates. Allow them once more after this update; after that, never again.

## 0.3.0 — 2026-11-11
- Settings › Permissions: the Accessibility state is always shown, with a button to its System Settings page (to turn it on or off).
- Check for Updates also runs by itself once every 2 weeks (Settings › "Check every 2 weeks" turns it off). It reads only the version number and speaks only when a newer version is out.
- Settings and Check for Updates are the first items in the menu bar menu.
- Black app icon; the README shows the blue one in GitHub dark mode.
