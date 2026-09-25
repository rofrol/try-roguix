# Contributing

Thanks for helping improve Try Roguix. The project has one product target: a
native Apple Silicon macOS app that runs Roguix — Guix System with the pinned
upstream Omarchy desktop — in a project-built ARM64 virtual machine image.

## Pull requests

Small fixes and documentation improvements are welcome without an issue first.
For large behavioral or architecture changes, open an issue to discuss the idea
before starting work.

Keep each PR focused and explain what changed, why, and how you tested it. Run
relevant tests when you can (`make test` runs the full suite on macOS), and say
what you could not check. Documentation-only changes do not need an app build
or the full test suite. Screenshots or a short video are helpful when they make
UI changes easier to review.

Update documentation when usage or requirements change. If you change build
inputs, review their pins and checksums and run the relevant component build;
explain any validation you could not complete. See the details below.

## Reporting issues

Before opening a report or proposal, search open and closed issues for the same
problem or idea. Add useful details to an existing issue, or link related issues
in your new report.

Tell us what happened, what you expected, and whether it happens in the Mac app
or inside Omarchy. Include your app version, macOS version, Apple chip, and
steps to reproduce if known. Logs, screenshots, and recordings are optional;
remove secrets and unrelated personal information before sharing them.

You can open a report even if you cannot reliably reproduce the problem or do
not know every system detail. For change proposals, describe the problem and
what you would like to improve; a full implementation plan is not needed.

Report suspected vulnerabilities through [SECURITY.md](SECURITY.md), not public
issues. Coding agents should also read [AGENTS.md](AGENTS.md).

## Build inputs and local state

The guest and QEMU supply chains are deliberately pinned. Do not update a URL,
commit, package lock, archive, or checksum independently of its associated
validation code.

Generated files in `dist/` and build caches in `macos/.build/` are not
committed. Use `make clean` to remove project build
artifacts and caches. `make clean-all` additionally destroys persistent local
VM data and should only be used when a complete reset is intended.

Component builds use content-hashed state under `.build/state/`. A state file is
published only after the build succeeds and its output passes validation. Use
`FORCE=1` when reviewing reproducibility or when an intentionally unchanged
input must be rebuilt; do not work around the cache by editing generated state.

## Updating Omarchy

Omarchy is the `omarchy` package in `guest/guix/modules/roguix/omarchy.scm`,
pinned to an upstream commit and its `guix hash -rx` digest. To update it,
change both, then review the upstream diff against what Roguix rewrites at
build time: the menu (`omarchy-menu.py`, which drops Arch-only entries), the
package helpers replaced with `roguix-pkg`, and the two `MenuModel.js`
substitutions (`test_omarchy_menu.py` pins that each still matches exactly
once). Omarchy's own names (`omarchy-*`, `OMARCHY_PATH`) are never renamed, so
an update stays a commit and hash change. Run `make test`, build the image
(`guest/guix/README.md`), package it with `make guix-package`, and check the
desktop in the app.

## Tests

Tests should describe a user-visible behavior, policy, data contract, or
process boundary. Keep presentation and edit rules in deterministic models that
can be exercised without opening AppKit windows. Do not make CI depend on pixel
coordinates, font metrics, display size, global window lookup, fixed run-loop
delays, or an assumed free network port.

Platform integration tests are appropriate when the operating-system boundary
is itself the contract. Use isolated temporary state, inject controllable
probes where the real resource is incidental, and use bounded readiness checks
instead of fixed settling delays.

By contributing, you agree that your contribution is licensed under the MIT
License in this repository.
