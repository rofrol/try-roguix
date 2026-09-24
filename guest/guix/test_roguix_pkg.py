"""roguix-pkg: configuration edits, reconfigure and queries."""

import importlib.machinery
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock

path = Path(__file__).with_name("modules") / "roguix" / "roguix-pkg"
loader = importlib.machinery.SourceFileLoader("guix_pkg", str(path))
spec = importlib.util.spec_from_loader("guix_pkg", loader)
pkg = importlib.util.module_from_spec(spec)
loader.exec_module(pkg)

TEMPLATE = '''(use-modules (roguix system))

(roguix-operating-system
 #:packages
 '(;; BEGIN roguix packages
   ;; END roguix packages
   ))
'''


class GuixPkgTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        self.config = root / "config.scm"
        self.config.write_text(TEMPLATE)
        manifest = root / "manifest"
        # As guix writes it: one field per line.
        manifest.write_text(
            '(manifest\n  (version 4)\n  (packages\n'
            '    (("foot"\n      "1.2"\n      "out"\n      "/gnu/store/a-foot")\n'
            '     ("jq"\n      "1.7"\n      "out"\n      "/gnu/store/b-jq"))))\n')
        patches = [mock.patch.object(pkg, "CONFIG", str(self.config)),
                   mock.patch.object(pkg, "PROFILE_MANIFEST", str(manifest)),
                   mock.patch.object(pkg.os, "geteuid", lambda: 0),
                   mock.patch.object(pkg.subprocess, "run", side_effect=self.fake_run)]
        for patcher in patches:
            patcher.start()
            self.addCleanup(patcher.stop)
        self.runs = []
        self.available = {"alacritty", "helix", "netcat-openbsd"}
        self.reconfigure_status = 0

    def fake_run(self, command, **kwargs):
        self.runs.append(command)
        if command[0] == pkg.GUIX:
            name = command[-1].strip("^$").replace("\\", "")
            out = f"{name}\t1.0\tout\tgnu/packages/x.scm:1:0\n" if name in self.available else ""
            return mock.Mock(returncode=0, stdout=out)
        return mock.Mock(returncode=self.reconfigure_status)

    def test_add_edits_the_config_and_reconfigures(self):
        self.assertEqual(pkg.main(["add", "alacritty", "netcat-openbsd"]), 0)
        self.assertEqual(pkg.config_packages(self.config.read_text()),
                         ["alacritty", "netcat-openbsd"])
        self.assertEqual(self.runs[-1], [pkg.RECONFIGURE])
        self.assertIn('   "alacritty"\n   "netcat-openbsd"\n   ;; END roguix packages',
                      self.config.read_text())

    def test_installed_or_listed_does_nothing(self):
        self.assertEqual(pkg.main(["add", "foot"]), 0)
        self.assertEqual(self.config.read_text(), TEMPLATE)
        self.assertNotIn([pkg.RECONFIGURE], self.runs)

    def test_names_guix_does_not_package_are_refused(self):
        for name in ("google-chrome", "ghostty"):
            with self.subTest(name=name):
                self.assertEqual(pkg.main(["add", name]), 1)
                self.assertEqual(self.config.read_text(), TEMPLATE)

    def test_failed_reconfigure_restores_the_config(self):
        self.reconfigure_status = 1
        self.assertEqual(pkg.main(["add", "helix"]), 1)
        self.assertEqual(self.config.read_text(), TEMPLATE)

    def test_remove_drops_from_the_list(self):
        pkg.main(["add", "alacritty", "helix"])
        self.assertEqual(pkg.main(["remove", "alacritty"]), 0)
        self.assertEqual(pkg.config_packages(self.config.read_text()), ["helix"])

    def test_present_and_list_use_the_system_profile(self):
        self.assertEqual(pkg.main(["present", "foot"]), 0)
        self.assertEqual(pkg.main(["present", "foot", "alacritty"]), 1)
        self.assertEqual(pkg.main(["list"]), 0)
        self.assertEqual(pkg.main(["frobnicate"]), 1)

    def test_changes_need_root(self):
        with mock.patch.object(pkg.os, "geteuid", lambda: 1000):
            self.assertEqual(pkg.main(["add", "helix"]), 1)
        self.assertEqual(self.config.read_text(), TEMPLATE)

    def test_damaged_block_is_refused(self):
        self.config.write_text("(roguix-operating-system)\n")
        self.assertEqual(pkg.main(["add", "helix"]), 1)


if __name__ == "__main__":
    unittest.main()
