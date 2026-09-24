"""The busctl shim translates Omarchy's exact calls into gdbus calls."""

import importlib.machinery
import importlib.util
from pathlib import Path
import unittest

path = Path(__file__).with_name("modules") / "try-guix" / "busctl"
loader = importlib.machinery.SourceFileLoader("busctl_shim", str(path))
spec = importlib.util.spec_from_loader("busctl_shim", loader)
busctl = importlib.util.module_from_spec(spec)
loader.exec_module(busctl)


class BusctlShimTests(unittest.TestCase):
    def test_notification_send_call(self):
        # bin/omarchy-notification-send's notify_cmd with two string hints.
        argv = ["--user", "--", "call", "org.freedesktop.Notifications",
                "/org/freedesktop/Notifications", "org.freedesktop.Notifications",
                "Notify", "susssasa{sv}i", "Omarchy", "0", "", "It's done",
                "-rf body", "0", "2", "omarchy-glyph", "s", "",
                "image-path", "s", "/tmp/a b.png", "-1"]
        self.assertEqual(busctl.command(argv), [
            "gdbus", "call", "--session", "--dest", "org.freedesktop.Notifications",
            "--object-path", "/org/freedesktop/Notifications",
            "--method", "org.freedesktop.Notifications.Notify",
            "'Omarchy'", "uint32 0", "''", "'It\\'s done'", "'-rf body'", "@as []",
            "@a{sv} {'omarchy-glyph': <''>, 'image-path': <'/tmp/a b.png'>}",
            "int32 -1"])

    def test_server_information_and_property(self):
        self.assertEqual(busctl.command(
            ["--user", "call", "org.freedesktop.Notifications",
             "/org/freedesktop/Notifications", "org.freedesktop.Notifications",
             "GetServerInformation"])[-1],
            "org.freedesktop.Notifications.GetServerInformation")
        self.assertEqual(busctl.command(
            ["get-property", "org.freedesktop.UPower", "/org/freedesktop/UPower",
             "org.freedesktop.UPower", "OnBattery"])[2:3], ["--system"])

    def test_replies_use_busctl_format(self):
        self.assertEqual(busctl.busctl_reply("(uint32 42,)\n"), "u 42")
        self.assertEqual(busctl.busctl_reply("(<false>,)\n"), "b false")
        self.assertEqual(busctl.busctl_reply("()\n"), "()")

    def test_unsupported_input_is_refused(self):
        for argv in (["monitor"], ["--json=short", "call", "a", "b", "c", "d"],
                     ["call", "a", "b", "c", "d", "a{sv}", "1", "k", "b", "true"],
                     ["call", "a", "b", "c", "d", "s"]):
            with self.subTest(argv=argv), self.assertRaises(busctl.Usage):
                busctl.command(argv)


if __name__ == "__main__":
    unittest.main()
