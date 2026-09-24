"""Contracts of the temporary Guix smoke launcher; no VM or GUI is started."""

import contextlib
import importlib.util
import io
from pathlib import Path
import shlex
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("guix_smoke", Path(__file__).with_name("run.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class SmokeLauncherTests(unittest.TestCase):
    def test_reuses_accelerated_runtime_without_cpu_or_gpu_software_fallback(self):
        command = runner.qemu_command(Path("/image.raw"), Path("/uefi.fd"))
        self.assertEqual(command[0], str(runner.QEMU))
        self.assertIn("virt,accel=hvf,gic-version=3", command)
        self.assertIn("host,pmu=off", command)
        self.assertTrue(any(arg.startswith("virtio-gpu-gl-pci,") for arg in command))
        display = command[command.index("-display") + 1]
        self.assertIn("cocoa,gl=es,", display)
        self.assertIn("full-grab=off", display)

    def test_firmware_is_the_pinned_runtime_copy(self):
        self.assertEqual(runner.FIRMWARE.parent.parent.parent, runner.RUNTIME)
        manifest = runner.ROOT / "macos/runtime-files.txt"
        listed = manifest.read_text(encoding="ascii").splitlines()
        self.assertIn(runner.FIRMWARE.relative_to(runner.RUNTIME).as_posix(), listed)

    def test_disk_is_ephemeral_and_host_integrations_are_not_exposed(self):
        command = runner.qemu_command(Path("/image.raw"), Path("/uefi.fd"))
        self.assertIn("-snapshot", command)
        self.assertIn("-nodefaults", command)
        self.assertEqual(command[command.index("-netdev") + 1], "user,id=net")
        self.assertFalse(any("hostfwd" in arg for arg in command))
        for option in ("-fsdev", "-virtfs", "-audiodev", "-qmp"):
            self.assertNotIn(option, command)
        self.assertFalse(any("virtserialport" in arg for arg in command))

    def test_paths_cannot_inject_qemu_drive_options(self):
        for name in ("disk image.raw", "disk,snapshot=off.raw", "'quoted'.raw"):
            with self.subTest(name=name):
                image = Path("/tmp") / name
                command = runner.qemu_command(image, Path("/EFI firmware.fd"))
                drive = command[command.index("-drive") + 1]
                self.assertIn("file=" + str(image).replace(",", ",,"), drive)
                self.assertEqual(command[command.index("-bios") + 1], "/EFI firmware.fd")
                self.assertEqual(shlex.split(shlex.join(command)), command)

    def test_dry_run_does_not_require_files_or_execute_anything(self):
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / "not-created.raw"
            argv = ["run.py", "--dry-run", "--image", str(image)]
            with patch.object(sys, "argv", argv), \
                 patch.object(runner, "FIRMWARE", Path(directory) / "not-created.fd"), \
                 patch.object(runner.os, "execv") as execute, \
                 patch.object(runner.subprocess, "run") as subprocess_run, \
                 contextlib.redirect_stdout(output):
                runner.main()
            execute.assert_not_called()
            subprocess_run.assert_not_called()
            self.assertEqual(list(Path(directory).iterdir()), [])
            self.assertIn("-snapshot", shlex.split(output.getvalue()))

    def test_invalid_runtime_signature_prevents_launch(self):
        import subprocess

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture"
            path.write_bytes(b"fixture")
            argv = ["run.py", "--image", str(path)]
            with patch.object(sys, "argv", argv), \
                 patch.object(runner, "QEMU", path), \
                 patch.object(runner, "FIRMWARE", path), \
                 patch.object(runner.platform, "system", return_value="Darwin"), \
                 patch.object(runner.platform, "machine", return_value="arm64"), \
                 patch.object(runner.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "codesign")), \
                 patch.object(runner.os, "execv") as execute, \
                 contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    runner.main()
                self.assertEqual(error.exception.code, 1)
                execute.assert_not_called()
            self.assertEqual(path.read_bytes(), b"fixture")


if __name__ == "__main__":
    unittest.main()
