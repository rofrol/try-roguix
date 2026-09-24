#!/usr/bin/env python3
"""Turn Omarchy's menu into Try Guix's: omarchy-menu.py UPSTREAM OUTPUT.

Omarchy's Install, Remove and Update menus manage Arch and AUR packages
(pacman, yay) and Omarchy's Arch update channels. On Try Guix every program
comes from Guix and is part of /etc/config.scm, so those entries are dropped
and replaced with Guix ones: a picker over all Guix packages, curated
programs Guix packages, and the Guix system's own apply, edit and roll-back.
Everything else in the menu is Omarchy's, unchanged.
"""

import json
import re
import sys

# Omarchy entries (and everything under them) with no Guix meaning.
DROPPED = (
    "install.aur", "install.windows", "install.preinstalls", "install.ai",
    "install.service", "install.browser", "install.editor", "install.terminal",
    "install.development", "install.gaming", "install.style.font",
    "remove.browser", "remove.development", "remove.dictation", "remove.gaming",
    "remove.service", "remove.windows", "remove.preinstalls", "remove.security",
    "update.omarchy", "update.channel", "update.firmware",
    "update.config.plymouth", "update.password.drive",
)

TERMINAL = "omarchy-launch-floating-terminal-with-presentation"
PINNED_GUIX = "/var/guix/gcroots/try-guix-guix/bin/guix"

# (menu id, label, Guix packages offered: (id suffix, label, package)).
CURATED = (
    ("install.terminal", "Terminal", (
        ("alacritty", "Alacritty", "alacritty"), ("kitty", "Kitty", "kitty"),
        ("wezterm", "WezTerm", "wezterm"), ("foot", "Foot", "foot"))),
    ("install.editor", "Editor", (
        ("helix", "Helix", "helix"), ("neovim", "Neovim", "neovim"),
        ("vim", "Vim", "vim"), ("emacs", "Emacs", "emacs-pgtk"),
        ("kakoune", "Kakoune", "kakoune"))),
    ("install.browser", "Browser", (
        ("librewolf", "LibreWolf", "librewolf"), ("icecat", "IceCat", "icecat"),
        ("chromium", "Ungoogled Chromium", "ungoogled-chromium"),
        ("qutebrowser", "qutebrowser", "qutebrowser"))),
    ("install.development", "Development", (
        ("go", "Go", "go"), ("rust", "Rust", "rust"), ("python", "Python", "python"),
        ("node", "Node.js", "node"), ("zig", "Zig", "zig"), ("ocaml", "OCaml", "ocaml"),
        ("java", "Java", "openjdk"), ("ruby", "Ruby", "ruby"), ("php", "PHP", "php"),
        ("elixir", "Elixir", "elixir"), ("clojure", "Clojure", "clojure"),
        ("c", "C and C++", "gcc-toolchain"))),
    ("install.gaming", "Gaming", (("retroarch", "RetroArch", "retroarch"),)),
    ("install.style.font", "Font", (
        ("iosevka", "Iosevka", "font-iosevka"),
        ("fira", "Fira Code", "font-fira-code"),
        ("victor", "Victor Mono", "font-victor-mono"),
        ("meslo", "Meslo LG", "font-meslo-lg"))),
)


def load(path):
    text = open(path, encoding="utf-8").read()
    # JSONC: whole-line comments and trailing commas. Strings may contain
    # "//" (URLs), so only comments that start a line are removed.
    text = re.sub(r"^\s*//.*$", "", text, flags=re.MULTILINE)
    text = re.sub(r",(\s*[}\]])", r"\1", text)
    return json.loads(text)


def dropped(entry_id):
    return any(entry_id == prefix or entry_id.startswith(prefix + ".")
               for prefix in DROPPED)


def transform(menu):
    result = {key: value for key, value in menu.items() if not dropped(key)}
    result["install.package"] = dict(
        menu["install.package"], label="Package",
        description="Any Guix package, added to /etc/config.scm",
        action=f"{TERMINAL} 'try-guix-pkg pick-add'")
    result["remove.package"] = dict(
        menu["remove.package"], label="Package",
        description="A package added in /etc/config.scm",
        action=f"{TERMINAL} 'try-guix-pkg pick-remove'")
    for group, label, programs in CURATED:
        icon = menu.get(group, {}).get("icon", "")
        result[group] = {"icon": icon, "label": label}
        for suffix, name, package in programs:
            upstream = menu.get(f"{group}.{suffix}", {})
            result[f"{group}.{suffix}"] = {
                "icon": upstream.get("icon", icon),
                "label": name,
                "description": f"Guix package {package}",
                "action": f"{TERMINAL} 'sudo try-guix-pkg add {package}'",
                "checked": f"try-guix-pkg present {package}",
            }
    result["update.system"] = {"icon": "", "label": "Guix System",
                               "aliases": ["reconfigure"]}
    result["update.system.apply"] = {
        "icon": "", "label": "Apply configuration",
        "description": "sudo try-guix-reconfigure (/etc/config.scm)",
        "action": f"{TERMINAL} try-guix-reconfigure"}
    result["update.system.edit"] = {
        "icon": "", "label": "Edit configuration",
        "description": "/etc/config.scm",
        "action": f"{TERMINAL} 'sudo nano /etc/config.scm'"}
    result["update.system.rollback"] = {
        "icon": "", "label": "Roll back",
        "description": "Boot the previous system generation's configuration",
        "action": f"{TERMINAL} 'sudo {PINNED_GUIX} system roll-back'"}
    return result


def main(argv):
    upstream, output = argv
    menu = transform(load(upstream))
    with open(output, "w", encoding="utf-8") as stream:
        stream.write("// Omarchy's menu for Try Guix (generated by omarchy-menu.py).\n")
        json.dump(menu, stream, ensure_ascii=False, indent=2)
        stream.write("\n")


if __name__ == "__main__":
    main(sys.argv[1:])
