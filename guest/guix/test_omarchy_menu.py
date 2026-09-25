"""omarchy-menu.py: Omarchy's menu without Arch, with Guix packages."""

import importlib.machinery
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).parent
path = HERE / "modules" / "roguix" / "omarchy-menu.py"
loader = importlib.machinery.SourceFileLoader("omarchy_menu", str(path))
spec = importlib.util.spec_from_loader("omarchy_menu", loader)
menu = importlib.util.module_from_spec(spec)
loader.exec_module(menu)

UPSTREAM = """// Omarchy menu
{
  "install": {"icon": "i", "label": "Install"},
  "install.package": {"icon": "p", "label": "Package", "action": "omarchy-pkg-install"},
  "install.aur": {"icon": "a", "label": "AUR", "action": "omarchy-pkg-aur-install"},
  "install.terminal": {"icon": "t", "label": "Terminal"},
  "install.terminal.ghostty": {"icon": "g", "label": "Ghostty",
    "action": "omarchy-pkg-add ghostty", "checked": "omarchy-pkg-present ghostty"},
  "remove.package": {"icon": "r", "label": "Package", "action": "omarchy-pkg-remove"},
  "update.omarchy": {"icon": "u", "label": "Omarchy", "action": "omarchy-update"},
  "style.theme": {"icon": "s", "label": "Theme", "action": "https://example.org",},
}
"""


class OmarchyMenuTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        upstream = Path(directory.name) / "menu.jsonc"
        upstream.write_text(UPSTREAM)
        output = Path(directory.name) / "out.jsonc"
        menu.main([str(upstream), str(output)])
        self.text = output.read_text()
        self.menu = menu.load(output)

    def test_no_arch_is_left(self):
        for word in ("pacman", "yay", "aur", "ghostty", "update.omarchy"):
            self.assertNotIn(word, self.text.lower().replace("roguix", ""))

    def test_guix_packages_and_system(self):
        self.assertIn("roguix-pkg pick-add", self.menu["install.package"]["action"])
        self.assertIn("roguix-pkg pick-remove", self.menu["remove.package"]["action"])
        self.assertEqual(self.menu["install.terminal.alacritty"]["checked"],
                         "roguix-pkg present alacritty")
        self.assertIn("sudo roguix-pkg add emacs-pgtk",
                      self.menu["install.editor.emacs"]["action"])
        self.assertIn("roguix-reconfigure", self.menu["update.system.apply"]["action"])
        self.assertEqual(self.menu["style.theme"]["action"], "https://example.org")


class OmarchyPackageTests(unittest.TestCase):
    def test_menu_guard_asks_guix(self):
        # MenuModel.js's installed-package guard reads pacman's database;
        # the build replaces exactly these two strings from Omarchy 4.0.4.
        source = (HERE / "modules/roguix/omarchy.scm").read_text()
        self.assertEqual(source.count('("pacman -Qq; LC_ALL=C pacman -Qi")'), 1)
        self.assertEqual(source.count('("pacman -Q \\"[$]1\\"")'), 1)
        self.assertNotIn('"pacman" "bin/"', source)
        self.assertNotIn('"yay"', source)


if __name__ == "__main__":
    unittest.main()
