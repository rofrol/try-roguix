# TODO

## Command shortcuts in the guest

Reported 2026-10-03: Command-Space does nothing in the guest, and
Command-Tab switches Mac apps.

Command-Space, found: the maintainer's Karabiner-Elements rule turns
Command-Space into F18 (for a Hammerspoon launcher) in its virtual HID
driver, before QEMU's event tap, so the guest gets F18. Exempt the VM window
in that rule's manipulator; the window belongs to QEMU, which has no bundle
identifier, so match its path (check it in Karabiner-EventViewer):

```json
{"type": "frontmost_application_unless",
 "file_paths": ["^.*/Try Roguix\\.app/Contents/Resources/runtime/bin/Try Roguix$"]}
```

Done 2026-10-03 in the maintainer's dotfiles (ef9ebbb), which also restored
the Emacs rule the F18 change had replaced. Still to do: test without the
F18 workaround, binding Cmd+Space in Hammerspoon directly after a logout
(the steps are in ~/.hammerspoon/init.lua); and document this for users of
Karabiner, Hammerspoon and AltTab: such tools may own a chord before the VM
sees it.

Command-Tab is left to macOS on purpose (`qemu-cocoa-command-tab.patch`), so
the keyboard can always leave the VM. Users who switch apps with AltTab want
it in the guest. Add a persisted setting, off by default, "Send Command-Tab
to Roguix" (start menu and settings), passed to QEMU's Cocoa display; with
it on, keep a host-only release shortcut handled before forwarding and show
it. Parallels' "Send macOS system shortcuts: Auto/Always/Never" is the
precedent if this grows beyond Command-Tab.

The Accessibility grant still matters for the rest:

Command-to-Super mapping of system shortcuts needs the Accessibility
permission (QEMU's full-grab CGEventTap; `FocusedCommandSuperBridge.swift`
is never started); without it the app starts the VM without the mapping and
only logs a warning. Development builds and
releases are signed ad hoc, so their designated requirement is the cdhash
(`codesign -d -r-` shows `designated => cdhash H"..."`): every rebuild or
update is a new identity for TCC, and the earlier grant no longer applies,
even if System Settings still shows it on. This is the leading hypothesis,
not yet proven.

- Diagnose: run only `~/Applications/Try Roguix.app`; check the start
  menu's Accessibility row, the `[input-bridge]` warning, and TCC denials
  (`log stream --predicate 'subsystem == "com.apple.TCC"'`). Log in the
  process that installs the tap: `AXIsProcessTrusted()`, tap creation,
  enabled state, callbacks. If the grant is fine, check tap re-enabling
  after `tapDisabledByTimeout`/`ByUserInput`, secure input
  (`ioreg -l -w 0 | grep SecureInput`), and that the tap swallows the event
  so Spotlight does not get Command-Space.
- Development builds: sign with a persistent local self-signed code-signing
  certificate (or Apple Development), so the designated requirement is the
  certificate and a grant survives rebuilds; keep the key in a dedicated
  build keychain.
- Releases: until there is a Developer ID, every ad-hoc update loses the
  grant. Tell the user after an update and offer a user-triggered
  re-grant (`tccutil reset Accessibility dev.tryroguix.native`, then the
  prompt); never reset automatically. A persistent self-signed release
  certificate would also keep grants across updates on other Macs, without
  solving Gatekeeper.

## The VM window shrinks on every guest reboot

Found 2026-10-03 while testing reboots: each guest reboot (`reboot(2)` in the
guest) leaves the VM window about 75% of its previous size (227x202,
171x160, 130x129 ... 22x48 points over ten reboots), with nobody touching it.
The 0.75 factor matches `cocoa_initial_window_frame` in
`qemu-cocoa-dynamic-display.patch`; check how a guest reset re-applies the
initial frame.

## Choose a VM instead of only resetting

Found 2026-10-03: `make run` used to set `OMARCHY_QEMU_GPU_DEVELOPMENT_MULTI_DISK=1`
and so created an identity-keyed disk beside `disks/current`; a Finder launch
then refused to start ("multiple saved VMs were found; use Reset Roguix"),
and Reset would erase both. `make run` no longer sets it (`make
run-isolated` does). The launcher should still offer a choice: list each
disk (factory image, size, last use, how it was created), keep the chosen
one as `current` and archive the others outside the scanned tree, with
Reset as one option rather than the only one. Adopt an identity disk
automatically only when it is the single candidate.

## Say why a launch did not happen

Reported 2026-10-03 twice: "Try Roguix does not start". Cause: a Dock tile
pinned to the old development build (`dist/app.noindex`), deleted by the
build-layout change; clicking it did nothing and logged nothing. The tile now
points to `~/Applications/Try Roguix.app`, and `make install` and
docs/architecture.md say to pin that copy.

The app could not have reported that, since it never ran. For failures after
it starts: keep the launcher's stderr in `~/Library/Logs/Try Roguix/` and
`os_log`, and replace the generic "couldn't start, reinstall" alert with the
log's last lines. Lower priority than the restart hang.

## Send the minimum guest size fix to Try Omarchy

`qemu-cocoa-minimum-guest-size.patch` fixes a hang that upstream shares: its
`qemu-cocoa-dynamic-display.patch` and QEMU's DEBUG EDK2 are the same, so a
guest reboot after a small window should hang there too. Kept as a separate
patch so rebases onto upstream do not conflict; offer it upstream (with the
firmware's ASSERT line as the reproducer) and drop ours once it lands. Upstream
QEMU's Cocoa UI also forwards the window size: reproduce on unpatched QEMU
before reporting it there.
