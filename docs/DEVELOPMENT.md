# HideBar internals

Notes for development. For what the app does, see the [README](../README.md).

## Why Hidden Bar breaks the clock

On macOS 27, Hidden Bar 1.11 hides icons through the private `MenuBarClientCore` (`MBAssessmentModeAssertion`), the menu bar visibility restriction behind exam mode. The system log shows it switching on with every hide:

```
Hidden Bar  [com.apple.menubar:visibility-restriction-xpc-client] VisibilityRestrictionAssertion session activated
```

While the restriction is active, Control Center doesn't pass clicks on the clock to Notification Center: `[com.apple.controlcenter:clock] Sending mouse down event to Notification Center` never appears in the log, and it does right after the restriction is lifted.

## How HideBar hides icons

On macOS 27, `MenuBarAgent` draws the menu bar and has its own overflow: whatever doesn't fit goes behind the system « button. The old trick of stretching a separator to 10,000 pt doesn't work there: the menu bar simply moves an item that wide into the overflow.

So HideBar sizes an empty separator item `|` to fill exactly the free space between the notch and the icons to its right. Everything left of `|` then goes into the overflow by itself. HideBar has no arrow of its own: there is one arrow in the menu bar, the system one.

- **Room by the notch** is chosen so that « doesn't fit left of the separator, and the system draws it over the separator's right end, right next to the visible icons.
- **Fitting.** The separator starts at the widest length. If it doesn't fit (for example, next to the system screen-recording pill), it shrinks in 24 pt steps. HideBar observes the separator window moving and notices this at once. If the anchor moved (icons to the right appeared or went away), it is measured again. If nothing fits at all, the next attempt waits 30 s so the icons don't flicker.
- **Displays without a notch.** The free width depends on the active app's menus, so it is found by bisection and cached per app.
- **Older macOS** without `MenuBarAgent` uses the classic scheme: a HideBar arrow plus a 10,000 pt separator.

### Is the overflow row open?

Clicking « makes macOS show the hidden icons in a separate row on the left, after the app's menus. There is no direct way to learn that, so HideBar keeps an invisible "sensor" item left of all icons: it always sits in the overflow, and its window turns visible (`occlusionState`) exactly while the row is open. No permission is needed for that.

When the row opens, HideBar reveals the icons in place: it shrinks the separator to a visible `|`, the icons settle right of the notch, and those that don't fit are placed by the system right next to the notch on the left. When the row is closed with », everything hides again. While the row is open, neither the shortcut nor a click on `|` collapses the icons, as they would land in that row; collapsing waits for ».

### Auto-hide through Accessibility

After the delay (10 s by default), when the pointer is outside the menu bar and no menu is open, HideBar presses » itself. That is the `MenuBarAgent` button with the identifier `menu-bar-overflow-indicator-expanded` (`menu-bar-overflow-indicator` while closed). HideBar only presses the button in its open state, and `AXPress` works without moving the pointer.

### Known limitation

When the screen-recording pill goes away, one hidden icon may take the freed space until the next click on « and ». Every hide starts fitting from the widest length, so it sorts itself out.

## Updates

HideBar updates itself with [Sparkle](https://sparkle-project.org). `SUFeedURL` in `Info.plist` points at `https://github.com/yxod/hidebar/releases/latest/download/appcast.xml`, the appcast attached to the latest release, and installed copies check it daily (or on **Check for Updates…**). Every update DMG carries an EdDSA signature that must match `SUPublicEDKey`; Sparkle also checks that the new app is signed by the same Developer ID.

The private half of the key sits in the login keychain, created once with:

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys      # prints the public key for SUPublicEDKey
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private-key.txt   # backup; keep it safe, not in git
```

Without that key no further update can be signed for existing installs, so keep a backup in a password manager. `release.sh` refuses to run when the keychain key and `SUPublicEDKey` differ.

`build.sh` copies `Sparkle.framework` into `Contents/Frameworks`, drops its XPC services (only sandboxed apps need them) and signs Sparkle's helpers, the framework and the app inside out. To try an update locally, serve a signed DMG and an appcast over `http://127.0.0.1` and point the app at it with `defaults write dev.qweb.HideBar SUFeedURL http://127.0.0.1:PORT/appcast.xml` (delete the key afterwards).

## Language

The interface is English unless Ukrainian is chosen in Settings. The choice is stored as `appLanguage` and applied as the app's `AppleLanguages` before the app starts, so switching restarts HideBar (with `--show-settings` to bring the window back). Strings live in `Resources/uk.lproj/Localizable.strings`, keyed by the English text.

## Debugging

`hidebar://debug` writes the separator and sensor geometry to the system log, where all layout decisions go too:

```bash
/usr/bin/log show --last 5m --predicate 'subsystem == "dev.qweb.HideBar"'
```

In zsh `log` is a builtin, hence the full path `/usr/bin/log`.

## Building

```bash
./build.sh            # build/HideBar.app, universal; Developer ID signature from the keychain (or ad-hoc)
./build.sh install    # also copies it to /Applications
swift scripts/make-icon.swift   # regenerate Resources/AppIcon.icns
```

Requires Xcode with Swift 6 and macOS 14+. With a Developer ID signature, macOS keeps the Accessibility permission across rebuilds.

## Releasing

`./release.sh 1.0.1` publishes a version on GitHub:
1. bumps the version in `Resources/Info.plist`;
2. builds the app signed with the Developer ID and Apple's timestamp;
3. packs it into `build/HideBar-1.0.1.dmg` (the app plus an Applications shortcut);
4. notarizes and staples the DMG, so Gatekeeper opens it without warnings;
5. commits the version, tags `v1.0.1` and pushes;
6. creates the release as a draft with the DMG and generated notes (add your own with `NOTES_FILE=notes.md`), builds `appcast.xml` with the update signature and those notes, attaches it and only then publishes the release.

Before the first release, store the notarization credentials once. The app-specific password is created at appleid.apple.com:

```bash
xcrun notarytool store-credentials hidebar-notary --apple-id you@example.com --team-id 2U5V9VG262
```

To check everything but publishing: `./release.sh 1.0.1 --dry-run` (with notarization) or `./release.sh 1.0.1 --dry-run --skip-notarize` (without). A dry run commits nothing and restores `Info.plist`.
