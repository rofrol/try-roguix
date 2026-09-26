"""roguix-setup: the first-start setup's config and suggestion handling."""

import base64
import importlib.machinery
import importlib.util
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).parent
path = HERE / "modules" / "roguix" / "roguix-setup"
loader = importlib.machinery.SourceFileLoader("roguix_setup", str(path))
spec = importlib.util.spec_from_loader("roguix_setup", loader)
setup = importlib.util.module_from_spec(spec)
loader.exec_module(setup)

TEMPLATE = """(use-modules (roguix system))

(roguix-operating-system
 ;; BEGIN roguix setup
 #:host-name "roguix"
 #:timezone "Etc/UTC"
 #:keyboard-layout "us"
 ;; END roguix setup
 #:packages
 '(;; BEGIN roguix packages
   ;; END roguix packages
   ))
"""


class SetupBlockTests(unittest.TestCase):
    def test_block_replaces_only_its_markers(self):
        block = setup.setup_block("studio", "Europe/Warsaw", "pl", "")
        text = setup.with_setup(TEMPLATE, block)
        self.assertIn('#:host-name "studio"', text)
        self.assertIn('#:timezone "Europe/Warsaw"', text)
        self.assertIn('#:keyboard-layout "pl"', text)
        self.assertNotIn("keyboard-variant", text)
        self.assertIn(";; BEGIN roguix packages", text)
        self.assertEqual(text.count(setup.BEGIN), 1)
        self.assertEqual(setup.with_setup(text, block), text)

    def test_variant_is_written_when_chosen(self):
        block = setup.setup_block("roguix", "UTC", "us", "dvorak")
        self.assertIn('#:keyboard-variant "dvorak"', block)

    def test_unsafe_values_never_reach_scheme(self):
        for value in ['x" (system "id") "', "a b", "é", "a\n"]:
            with self.assertRaises(setup.Failure):
                setup.setup_block(value, "UTC", "us", "")

    def test_a_config_without_one_block_is_refused(self):
        with self.assertRaises(setup.Failure):
            setup.with_setup(TEMPLATE.replace(setup.BEGIN, ""), "")
        with self.assertRaises(setup.Failure):
            setup.with_setup(TEMPLATE + setup.BEGIN, "")


class SuggestionTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.zoneinfo = Path(directory.name)
        for zone in ("Europe/Warsaw", "America/Argentina/Buenos_Aires", "UTC",
                     "Etc/GMT+1", "posix/Europe/Warsaw", "zone1970.tab"):
            (self.zoneinfo / zone).parent.mkdir(parents=True, exist_ok=True)
            (self.zoneinfo / zone).write_text("")
        self.settings = self.zoneinfo / "host-settings"

    def settings_with(self, text):
        self.settings.write_text(text)
        return setup.host_settings(str(self.settings))

    def test_layout_follows_the_mac_or_falls_back_to_us(self):
        mac = self.settings_with("tryomarchy.keyboard_layout=pl omarchy.qemu_virgl=1\n")
        self.assertEqual(setup.suggested_layout(mac)[0], "Polish")
        dvorak = self.settings_with("tryomarchy.keyboard_layout=us "
                                    "tryomarchy.keyboard_variant=dvorak\n")
        self.assertEqual(setup.suggested_layout(dvorak)[0], "English (US, Dvorak)")
        self.assertEqual(setup.suggested_layout({})[0], "English (US)")
        unknown = self.settings_with("tryomarchy.keyboard_layout=zz\n")
        self.assertEqual(setup.suggested_layout(unknown)[0], "English (US)")

    def test_timezone_is_decoded_and_checked_against_zoneinfo(self):
        encoded = base64.urlsafe_b64encode(b"Europe/Warsaw").decode().rstrip("=")
        settings = {"tryomarchy.timezone": encoded}
        original = setup.ZONEINFO
        setup.ZONEINFO = str(self.zoneinfo)
        self.addCleanup(setattr, setup, "ZONEINFO", original)
        self.assertEqual(setup.suggested_timezone(settings), "Europe/Warsaw")
        bad = base64.urlsafe_b64encode(b"../../etc/passwd").decode()
        self.assertEqual(setup.suggested_timezone({"tryomarchy.timezone": bad}), "Etc/UTC")
        self.assertEqual(setup.suggested_timezone({}), "Etc/UTC")

    def test_zone_list_offers_regions_and_utc(self):
        self.assertEqual(setup.zones(str(self.zoneinfo)),
                         ["America/Argentina/Buenos_Aires", "Europe/Warsaw", "UTC"])

    def test_every_layout_is_a_valid_scheme_value(self):
        for label, layout, variant, keymap in setup.LAYOUTS:
            setup.setup_block("roguix", "UTC", layout, variant)


if __name__ == "__main__":
    unittest.main()
