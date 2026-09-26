# Omarchy packages in Roguix

Omarchy 4.0.4 lists its default Arch packages in
`install/omarchy-base.packages` (150 entries). Roguix installs the Guix
equivalents through `%omarchy-applications` and the system definition in
`guest/guix/modules/roguix/`. This page lists only where Roguix differs, and
why. Everything not listed here is installed under the same or an obvious
Guix name (for example `nvim` as `neovim`, `networkmanager` as
`network-manager`, `noto-fonts-cjk` as `font-google-noto-sans-cjk`).

Checked on 2026-09-26 against Guix commit `7e74121a`, the pin in
`guest/guix/modules/roguix/guix-commit`.

## Not Omarchy: VLC and Qt 5

VLC is not an Omarchy package; Omarchy plays video with `mpv`, which Roguix
also has. Guix's OBS pulled in VLC 3 for its optional VLC video source, and
VLC brought the whole Qt 5 stack. Roguix builds OBS without it
(`obs-without-vlc`) and fcitx5-qt without its Qt 5 plugin (`fcitx5-qt6`), so
the system has no Qt 5; both refuse to build if Qt 5 comes back. Omarchy's
own applications use Qt 6 or GTK.

## Replaced by a Roguix counterpart

| Omarchy | Roguix | Why |
| --- | --- | --- |
| `chromium` | LibreWolf | Owner's choice of browser; web apps open in a new LibreWolf window |
| `sddm` | tty1 autologin into Hyprland | A single-user VM; the first-start setup sets the password |
| `uwsm` | `uwsm` shim | Guix has no systemd user session for uwsm to manage |
| `yay`, `expac`, `pacman-contrib`, `kernel-modules-hook` | `roguix-pkg`, `roguix-reconfigure`, `roguix-update` | Guix System replaces pacman and the AUR |
| `xdg-terminal-exec` | Try Omarchy's `xdg-terminal-exec` | The same tool, shipped with the compatibility commands |
| `omarchy-nvim` | Guix's `neovim` | Omarchy's Neovim configuration package is not packaged for Guix |
| `tzupdate` | The Mac's time zone | The launcher passes it to the first-start setup |

## Not in Guix at the pinned commit

| Omarchy | Notes |
| --- | --- |
| `pinta`, `localsend`, `obsidian` | .NET, Flutter and Electron applications; see `docs/decisions/0003-upstream-binary-packages.md` |
| `dotnet-runtime` | Only Pinta needs it |
| `aether`, `omacalc`, `omacut`, `omawrite`, `tensaku`, `tobi-try`, `ttfx`, `usage` | Omarchy-specific or Arch-only tools, not packaged for Guix |
| `hyprland-preview-share-picker` | Not packaged for Guix |
| `nautilus-python` | Not packaged for Guix |
| `docker-buildx` | Not packaged for Guix |
| `bluez-tools`, `asdcontrol` | Not packaged for Guix; the VM has no Bluetooth or Apple display hardware either |
| `ufw`, `ufw-docker` | Not packaged for Guix; the VM sits behind the Mac's QEMU user network |
| `ttf-ia-writer` | Not packaged for Guix |
| `herdr` | Not packaged for Guix |

## In Guix but not installed yet

Guix has these at the pinned commit; Roguix has not added them to the system
profile. `alsa-utils`, `bluez`, `libsecret` and `nss-mdns` are in the system
already, as dependencies, but their commands are not installed. Some only
matter on real hardware, which the VM does not have; the rest have simply
not been reviewed.

- Hardware the VM lacks: `bluez`, `bolt`
  (Thunderbolt), `ddcutil` (external monitors), `power-profiles-daemon`,
  `plymouth`, `wireless-regdb`.
- Printing: `cups`, `cups-filters`, `cups-pk-helper`, `system-config-printer`.
- Desktop pieces: `gnome-keyring`, `gnome-themes-extra`, `sushi`, `gvfs`
  (Omarchy's `gvfs-mtp`, `gvfs-nfs`, `gvfs-smb`), `udiskie`,
  `xdg-desktop-portal-gtk`, `xdg-desktop-portal-hyprland`,
  `ffmpegthumbnailer`, `mpv-mpris`, `gpu-screen-recorder`, `moonlight-qt`,
  `font-google-noto`, `font-google-noto-emoji`, `font-awesome`.
- Developer tools: `clang`, `llvm`, `ruby`, `lua@5.1`, `luarocks`, `mise`,
  `tree-sitter-cli`, `fakeroot`, `docker-compose`, `python-pygobject`,
  `python-poetry-core`, `mariadb`, `postgresql`, `vips`, `libyaml`,
  `qemu` (for `qemu-user-static-binfmt`).
- Utilities: `alsa-utils`, `bash-completion`, `exfatprogs`, `inxi`,
  `plocate`, `qrencode`, `zbar`, `nss-mdns`,
  `tesseract-ocr-tessdata-fast` (`tesseract-data-eng`).
- `libreoffice`: left out for now; see `%omarchy-applications`.

Omarchy's optional list, `install/omarchy-other.packages`, is not covered
here.
