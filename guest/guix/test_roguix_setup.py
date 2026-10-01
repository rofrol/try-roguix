"""roguix-setup: the first-start setup's config and suggestion handling."""

import base64
import io
import os
import pty
import signal
import termios
import importlib.machinery
import importlib.util
from pathlib import Path
import tempfile
import unittest
import unittest.mock

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

    def test_zoneinfo_comes_from_tzdir(self):
        with unittest.mock.patch.dict("os.environ", {"TZDIR": str(self.zoneinfo)}):
            self.assertEqual(setup.system_zoneinfo(), str(self.zoneinfo))

    def test_session_bus_comes_from_the_compositor(self):
        proc = self.zoneinfo / "proc"
        uid = os.getuid()
        for pid, comm, bus in (("7", "waybar", "unix:path=/tmp/other"),
                               ("9", "Hyprland", "unix:path=/tmp/dbus-x")):
            (proc / pid).mkdir(parents=True)
            (proc / pid / "comm").write_text(comm + "\n")
            (proc / pid / "environ").write_bytes(
                b"A=1\0DBUS_SESSION_BUS_ADDRESS=" + bus.encode() + b"\0")
        self.assertEqual(setup.session_bus(uid, str(proc)), "unix:path=/tmp/dbus-x")
        self.assertIsNone(setup.session_bus(uid + 1, str(proc)))

    def test_zone_list_offers_regions_and_utc(self):
        self.assertEqual(setup.zones(str(self.zoneinfo)),
                         ["America/Argentina/Buenos_Aires", "Europe/Warsaw", "UTC"])

    def test_every_layout_is_a_valid_scheme_value(self):
        for label, layout, variant, keymap in setup.LAYOUTS:
            setup.setup_block("roguix", "UTC", layout, variant)


class TerminalTests(unittest.TestCase):
    """The one-process questions: typeahead, validation, keys and events."""

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        zoneinfo = Path(directory.name)
        for zone in ("Europe/Warsaw", "Europe/Berlin", "America/New_York"):
            (zoneinfo / zone).parent.mkdir(parents=True, exist_ok=True)
            (zoneinfo / zone).write_text("")
        original = (setup.ZONEINFO, setup.apply_layout)
        setup.ZONEINFO = str(zoneinfo)
        setup.apply_layout = lambda entry: None
        self.addCleanup(lambda: (setattr(setup, "ZONEINFO", original[0]),
                                 setattr(setup, "apply_layout", original[1])))
        self.settings = {
            "tryomarchy.keyboard_layout": "pl",
            "tryomarchy.timezone": base64.urlsafe_b64encode(
                b"Europe/Warsaw").decode().rstrip("="),
        }

    def run_with(self, keys):
        """ask_all with KEYS already typed, as if typed ahead of every question."""
        read_fd, write_fd = os.pipe()
        os.write(write_fd, keys.encode())
        os.close(write_fd)
        output = open(os.devnull, "wb")
        self.addCleanup(output.close)
        self.addCleanup(os.close, read_fd)
        events = io.StringIO()
        with setup.Terminal(read_fd, output.fileno(), events) as terminal:
            answers = setup.ask_all(terminal, self.settings)
        return answers, events.getvalue().splitlines()

    def test_answers_typed_ahead_all_arrive_in_order(self):
        keys = ("\r" "secret1\r" "secret1\r" "Ada Lovelace\r" "ada@example.com\r"
                "\x15studio\r" "\r" "\r")
        (layout, password, name, email, host, zone), events = self.run_with(keys)
        self.assertEqual(layout[0], "Polish")
        self.assertEqual((password, name, email, host, zone),
                         ("secret1", "Ada Lovelace", "ada@example.com", "studio",
                          "Europe/Warsaw"))
        self.assertEqual([event for event in events if " ready " in event],
                         [f"roguix-setup: ready {step}" for step in (
                             "keyboard", "password", "password-repeat", "git-name",
                             "git-email", "host-name", "time-zone", "confirm")])
        self.assertIn("roguix-setup: accepted confirm yes", events)

    def test_rejections_ask_again_and_are_announced(self):
        keys = ("\r" "\r" "one\r" "two\r" "pass\r" "pass\r" "\r" "\r"
                "\x15Bad_Name\r" "\x15good\r" "\r" "n" "\r"
                "\r" "\r" "\r" "\r" "\r")
        (layout, password, name, email, host, zone), events = self.run_with(keys)
        self.assertEqual((password, host), ("pass", "roguix"))
        self.assertIn("roguix-setup: rejected password The password must not be empty.",
                      events)
        self.assertIn("roguix-setup: rejected password The passwords differ.", events)
        self.assertTrue(any(event.startswith("roguix-setup: rejected host-name")
                            for event in events))
        self.assertIn("roguix-setup: accepted confirm no", events)
        self.assertEqual(events[-1], "roguix-setup: accepted confirm yes")

    def test_search_and_arrow_keys_pick_another_item(self):
        keys = ("\r" "pw\r" "pw\r" "\r" "\r" "\r"
                "berl\r" "\r")
        answers, _ = self.run_with(keys)
        self.assertEqual(answers[5], "Europe/Berlin")
        keys = ("\x1b[A\r" "pw\r" "pw\r" "\r" "\r" "\r" "\r" "\r")
        answers, _ = self.run_with(keys)
        self.assertEqual(answers[0][0], "Norwegian")

    def test_raw_mode_keeps_keys_typed_before_it(self):
        master, slave = pty.openpty()
        self.addCleanup(os.close, master)
        self.addCleanup(os.close, slave)
        os.write(master, b"early\r")
        output = open(os.devnull, "wb")
        self.addCleanup(output.close)
        with setup.Terminal(slave, output.fileno()) as terminal:
            self.assertEqual(terminal.ask("probe", "Probe"), "early")

    def test_termination_restores_the_terminal(self):
        master, slave = pty.openpty()
        self.addCleanup(os.close, master)
        self.addCleanup(os.close, slave)
        output = open(os.devnull, "wb")
        self.addCleanup(output.close)
        with self.assertRaises(KeyboardInterrupt):
            with setup.Terminal(slave, output.fileno()):
                self.assertFalse(termios.tcgetattr(slave)[3] & termios.ECHO)
                os.kill(os.getpid(), signal.SIGTERM)
        restored = termios.tcgetattr(slave)[3]
        for flag in (termios.ICANON, termios.ECHO, termios.ISIG):
            self.assertTrue(restored & flag)

    def test_a_broken_event_channel_does_not_stop_the_setup(self):
        class Broken:
            def write(self, text):
                raise OSError("gone")
        read_fd, write_fd = os.pipe()
        os.write(write_fd, b"value\r")
        os.close(write_fd)
        self.addCleanup(os.close, read_fd)
        output = open(os.devnull, "wb")
        self.addCleanup(output.close)
        with setup.Terminal(read_fd, output.fileno(), Broken()) as terminal:
            self.assertEqual(terminal.ask("probe", "Probe"), "value")


if __name__ == "__main__":
    unittest.main()
