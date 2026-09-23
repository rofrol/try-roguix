"""Build planning and failure contracts; these do not boot or evaluate Guix."""

import argparse
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("guix_image_build", Path(__file__).with_name("build.py"))
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class BuildTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.args = argparse.Namespace(source=self.root, output=self.root / "out/image.raw", dry_run=True, check=False)

    def git(self, head=builder.COMMIT, changes=""):
        return patch.object(builder.subprocess, "check_output", side_effect=[head, changes, "a" * 40])

    def test_dry_run_is_read_only_and_pins_local_source_and_architecture(self):
        output = io.StringIO()
        with self.git(), patch.object(builder.subprocess, "run") as run, contextlib.redirect_stdout(output):
            builder.build(self.args)
        self.assertIn(str(self.root.resolve()), output.getvalue())
        self.assertIn(builder.COMMIT, output.getvalue())
        self.assertIn("--system=aarch64-linux", output.getvalue())
        self.assertIn("--image-type=efi-raw", output.getvalue())
        run.assert_not_called()
        self.assertEqual(list(self.root.iterdir()), [])

    def test_wrong_pin_and_tracked_changes_are_rejected(self):
        for head, changes in [("0" * 40, ""), (builder.COMMIT, " M gnu.scm")]:
            with self.subTest(head=head, changes=changes), self.git(head, changes):
                with self.assertRaises(ValueError):
                    builder.build(self.args)
        self.assertFalse(self.args.output.parent.exists())

    def test_existing_output_is_never_replaced_including_dangling_symlink(self):
        self.args.output.parent.mkdir()
        for symlink in (False, True):
            with self.subTest(symlink=symlink):
                if symlink:
                    self.args.output.symlink_to(self.root / "missing")
                else:
                    self.args.output.write_text("keep")
                with self.git(), self.assertRaises(ValueError):
                    builder.build(self.args)
                self.assertTrue(os.path.lexists(self.args.output))
                self.args.output.unlink()

    def test_macos_build_fails_before_creating_output(self):
        self.args.dry_run = False
        with self.git(), patch.object(builder.platform, "system", return_value="Darwin"):
            with self.assertRaisesRegex(ValueError, "Build on Linux"):
                builder.build(self.args)
        self.assertFalse(self.args.output.parent.exists())

    def test_build_failure_propagates_and_temporary_channel_is_removed(self):
        self.args.dry_run = False
        channels = []

        def fail(command, **kwargs):
            self.assertTrue(kwargs["check"])
            if command[0] == "git":
                return
            channel = Path(command[2].split("=", 1)[1])
            channels.append(channel)
            self.assertIn(builder.COMMIT, channel.read_text())
            self.assertIn("(inherit %default-guix-channel)", channel.read_text())
            self.assertNotIn("--disable-authentication", command)
            self.assertIn("--root=" + str(self.args.output), command)
            raise subprocess.CalledProcessError(1, command)

        with self.git(), patch.object(builder.platform, "system", return_value="Linux"), \
             patch.object(builder.shutil, "which", return_value="/bin/guix"), \
             patch.dict(os.environ, {"GUIX_GUEST_PASSWORD_HASH": "test-not-logged"}), \
             patch.object(builder.subprocess, "run", side_effect=fail):
            with self.assertRaises(subprocess.CalledProcessError):
                builder.build(self.args)
        self.assertEqual(len(channels), 1)
        self.assertFalse(channels[0].exists())
        self.assertFalse(self.args.output.exists())

    def test_check_plan_does_not_publish_an_image(self):
        self.args.check = True
        self.args.output.parent.mkdir()
        self.args.output.write_text("existing image")
        output = io.StringIO()
        with self.git(), contextlib.redirect_stdout(output):
            builder.build(self.args)
        self.assertIn("--dry-run", output.getvalue())
        self.assertNotIn("--root=", output.getvalue())
        self.assertEqual(self.args.output.read_text(), "existing image")

    def test_real_git_staging_exports_keyring_without_modifying_source(self):
        clean = builder.git_environment()
        real_run = subprocess.run  # captured before builder.subprocess.run is patched
        run = lambda command, **kw: real_run(command, **{"env": clean, **kw})
        run(["git", "init", "-q", str(self.root)], check=True)
        (self.root / "source.txt").write_text("channel fixture")
        run(["git", "-C", str(self.root), "add", "source.txt"], check=True)
        run(["git", "-C", str(self.root), "-c", "user.name=Test",
             "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture"], check=True)
        head = subprocess.check_output(["git", "-C", str(self.root), "rev-parse", "HEAD"], text=True, env=clean).strip()
        run(["git", "-C", str(self.root), "update-ref", "refs/remotes/origin/keyring", head], check=True)
        refs_before = subprocess.check_output(["git", "-C", str(self.root), "show-ref"], env=clean)
        self.args.dry_run = False
        self.args.check = True
        guix_calls = []

        def inspect(command, **kwargs):
            if command[0] != "guix":
                return run(command, **kwargs)
            guix_calls.append(command)
            channels = Path(command[2].split("=", 1)[1])
            source = channels.parent / "source.git"
            keyring = subprocess.check_output(
                ["git", "-C", str(source), "rev-parse", "refs/heads/keyring"], text=True, env=clean,
            ).strip()
            self.assertEqual(keyring, head)
            self.assertIn("(inherit %default-guix-channel)", channels.read_text())
            self.assertIn(source.as_uri(), channels.read_text())
            self.assertIn("--dry-run", command)
            self.assertFalse(any(arg.startswith("--root=") for arg in command))
            return subprocess.CompletedProcess(command, 0)

        with patch.object(builder, "COMMIT", head), \
             patch.object(builder.platform, "system", return_value="Linux"), \
             patch.object(builder.shutil, "which", return_value="/bin/guix"), \
             patch.dict(os.environ, {"GUIX_GUEST_PASSWORD_HASH": "test-not-logged"}), \
             patch.object(builder.subprocess, "run", side_effect=inspect), \
             contextlib.redirect_stdout(io.StringIO()):
            builder.build(self.args)
        self.assertEqual(len(guix_calls), 1)
        self.assertFalse(self.args.output.parent.exists())
        self.assertEqual(refs_before, subprocess.check_output(["git", "-C", str(self.root), "show-ref"], env=clean))
        self.assertEqual(subprocess.check_output(["git", "-C", str(self.root), "status", "--porcelain"], env=clean), b"")

    def test_isolation_list_covers_installed_git(self):
        names = subprocess.run(["git", "rev-parse", "--local-env-vars"], check=True,
                               text=True, capture_output=True).stdout.split()
        self.assertTrue(set(names) <= builder.GIT_LOCAL_ENV_VARS, set(names) - builder.GIT_LOCAL_ENV_VARS)

    def test_inherited_git_dir_cannot_redirect_pin_checks(self):
        decoy = self.root / "decoy.git"
        subprocess.run(["git", "init", "-q", "--bare", str(decoy)], check=True, env=builder.git_environment())
        with patch.dict(os.environ, {"GIT_DIR": str(decoy), "GIT_WORK_TREE": str(self.root)}):
            env = builder.git_environment()
        self.assertNotIn("GIT_DIR", env)
        self.assertNotIn("GIT_WORK_TREE", env)
        self.assertIn("PATH", env)


if __name__ == "__main__":
    unittest.main()
