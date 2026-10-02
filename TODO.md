# TODO

## Command is not captured as Super in the guest

Reported 2026-10-03: inside the VM, Command shortcuts such as Command-Space
do nothing; the Mac keeps them.

Command-to-Super mapping needs the Accessibility permission (a modifying
CGEventTap, `FocusedCommandSuperBridge.swift`); without it the app starts
the VM without the mapping and only logs a warning. Development builds and
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

## Restart from inside the guest hangs in the firmware

Found 2026-10-03 on b37: `sudo reboot` in the guest resets QEMU
(`-action reboot=reset`), but the VM stays in EDK2 (the program counter is
in firmware, nothing reaches the console) and never boots. Shutting down and
launching again works. Not yet known whether earlier images behave the same.
