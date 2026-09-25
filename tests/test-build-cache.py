#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPOSITORY / "scripts"))
SPEC = importlib.util.spec_from_file_location(
    "try_omarchy_build_cache", REPOSITORY / "scripts/build-cache.py"
)
assert SPEC is not None and SPEC.loader is not None
build_cache = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build_cache)


FAKE_BUILDER = textwrap.dedent(
    r"""
    from pathlib import Path
    import sys
    import time

    root = Path(sys.argv[1])
    mode = sys.argv[2]
    count_path = root / "build-count"
    count = int(count_path.read_text()) + 1 if count_path.exists() else 1
    count_path.write_text(f"{count}\n")
    if mode == "fail":
        raise SystemExit(23)
    if mode == "slow":
        time.sleep(0.2)
    if mode == "mutate":
        (root / "input/build.input").write_text("changed during build\n")
    (root / "out").mkdir(exist_ok=True)
    (root / "out/artifact").write_text(f"build {count}\n")
    """
)

# The cache runner is generic; these tests drive it with a fake component
# whose input is input/build.input and whose output is out/artifact.
FAKE_COMPONENT = textwrap.dedent(
    r"""
    import importlib.util
    from pathlib import Path
    import sys

    # build-cache.py imports its sibling app_version module.
    sys.path.insert(0, str(Path(sys.argv[1]).parent))
    spec = importlib.util.spec_from_file_location("build_cache", sys.argv.pop(1))
    build_cache = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(build_cache)

    def component_files(root, component):
        return [root / "input/build.input"]

    def validate_outputs(root, component, previous):
        path = root / "out/artifact"
        if not path.is_file():
            raise build_cache.CacheError("fake artifact is missing")
        snapshot = {"artifact": path.read_text()}
        if previous is not None and previous.get("outputs") != snapshot:
            raise build_cache.CacheError("fake artifact changed")
        return snapshot

    build_cache.component_files = component_files
    build_cache.validate_outputs = validate_outputs
    build_cache.main()
    """
)


class BuildCacheTests(unittest.TestCase):
    @staticmethod
    def prepare_fake_component(root: Path) -> None:
        (root / "input").mkdir()
        (root / "input/build.input").write_text("initial\n")

    def test_make_orders_components_and_propagates_force(self) -> None:
        dry_run = subprocess.run(
            ["make", "-n", "build"],
            cwd=REPOSITORY,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        ).stdout
        runtime = dry_run.index(" runtime --")
        app = dry_run.index(" app --")
        self.assertLess(runtime, app)
        self.assertNotIn(" guest --", dry_run)
        self.assertIn('--guest-dir "' + str(REPOSITORY / "dist/guix") + '"', dry_run)
        self.assertIn("Build output:", dry_run)
        self.assertIn(
            str(REPOSITORY / "dist/app.noindex/Try Roguix.app"), dry_run
        )

        forced = subprocess.run(
            ["make", "-n", "build", "FORCE=1"],
            cwd=REPOSITORY,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        ).stdout
        self.assertEqual(2, forced.count('OMARCHY_FORCE_BUILD="1"'))

        invalid_release = subprocess.run(
            ["make", "release", "RELEASE_SIGN_IDENTITY=invalid"],
            cwd=REPOSITORY,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        self.assertNotEqual(0, invalid_release.returncode)
        self.assertNotIn("build-cache.py", invalid_release.stdout)

    def test_development_app_is_excluded_from_spotlight(self) -> None:
        build_script = (REPOSITORY / "macos/build-app.sh").read_text()
        open_script = (REPOSITORY / "macos/open-qemu-gpu.sh").read_text()
        self.assertIn(
            'app="$repo_dir/dist/app.noindex/Try Roguix.app"',
            build_script,
        )
        self.assertIn(
            'legacy_app="$repo_dir/dist/Try Roguix.app"',
            build_script,
        )
        self.assertIn('rm -rf -- "$legacy_app"', build_script)
        self.assertNotIn(".metadata_never_index", build_script)
        self.assertIn(
            'app="$repo_dir/dist/app.noindex/Try Roguix.app"',
            open_script,
        )

    def test_runtime_file_manifest_is_the_single_validated_closure(self) -> None:
        manifest = REPOSITORY / "macos/runtime-files.txt"
        expected = frozenset(manifest.read_text(encoding="ascii").splitlines())
        self.assertEqual(expected, build_cache.RUNTIME_FILES)
        self.assertEqual(18, len(expected))
        self.assertIn("share/qemu/edk2-aarch64-code.fd", expected)
        self.assertIn("share/qemu/edk2-licenses.txt", expected)
        self.assertIn("bin/qemu-system-aarch64", expected)
        self.assertIn("bin/zstd", expected)
        self.assertIn("lib/libSDL3.dylib", expected)

        with tempfile.TemporaryDirectory() as temporary:
            invalid = Path(temporary) / "runtime-files.txt"
            for contents in (
                "",
                "bin/tool\nbin/tool\n",
                "../outside\n",
                "bin//tool\n",
                "lib/nested/tool\n",
                "share/tool\n",
                "share/qemu/nested/firmware\n",
            ):
                invalid.write_text(contents, encoding="ascii")
                with self.assertRaises(RuntimeError):
                    build_cache.read_runtime_manifest(invalid)

    def test_app_fingerprint_tracks_the_packaged_guix_guest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "macos/Sources").mkdir(parents=True)
            (root / "macos/Sources/main.swift").write_text("one\n")
            (root / "macos/README.md").write_text("first docs\n")
            (root / ".build/state").mkdir(parents=True)
            (root / ".build/state/runtime.json").write_text("{}\n")
            (root / "dist/guix").mkdir(parents=True)
            for name in build_cache.GUIX_GUEST_FILES:
                (root / name).write_text("first\n")
            paths = build_cache.component_files(root, "app")
            self.assertIn(root / "dist/guix/guix-manifest.json", paths)
            self.assertIn(root / "dist/guix/SHA256SUMS", paths)
            self.assertIn(root / "macos/Sources/main.swift", paths)
            self.assertNotIn(root / "macos/README.md", paths)
            self.assertFalse(any("dist/guest" in str(path) for path in paths))

    def test_app_validation_requires_packaged_icon(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "dist/app.noindex/Try Roguix.app"
            for relative in (
                "Contents/MacOS/omarchy-vm-helper",
                "Contents/Resources/runtime/bin/Try Roguix",
                "Contents/Resources/guest/disk.raw.zst",
                "Contents/Resources/guest/guix-manifest.json",
                "Contents/Resources/guest/launch.plist",
            ):
                path = app / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"fixture\n")

            with self.assertRaisesRegex(
                build_cache.CacheError, "app bundle is missing or unsafe"
            ):
                build_cache.validate_app(root, None)

    def test_app_fingerprint_tracks_git_version_without_source_changes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for relative in (
                "macos/Info.plist", "LICENSE", ".build/state/runtime.json",
                *build_cache.GUIX_GUEST_FILES,
                *(f"macos/.build/qemu-gpu-runtime/{name}" for name in build_cache.RUNTIME_FILES),
            ):
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("fixture\n")
            (root / ".gitignore").write_text("/dist/\n/.build/\n/macos/.build/\n")

            def git(*arguments: str) -> None:
                subprocess.run(
                    ["git", "-C", str(root), *arguments],
                    check=True, capture_output=True,
                )

            git("init", "-q")
            git("config", "user.name", "Cache Tests")
            git("config", "user.email", "cache-tests@example.invalid")
            git("add", ".")
            git("commit", "-qm", "Initial source")

            def fingerprint() -> str:
                return build_cache.fingerprint(root, "app", ["build-app"])

            untagged = fingerprint()
            git("tag", "v1.2.3")
            tagged = fingerprint()
            self.assertNotEqual(untagged, tagged)

            # A file outside the app inputs still makes its version dirty.
            untracked = root / "notes.txt"
            untracked.write_text("untracked\n")
            dirty = fingerprint()
            self.assertNotEqual(tagged, dirty)
            untracked.unlink()
            self.assertEqual(tagged, fingerprint())

            source = root / "macos/Info.plist"
            source.write_text("edited\n")
            dirty = fingerprint()
            git("add", ".")
            git("commit", "-qm", "Edit source")
            committed = fingerprint()
            self.assertNotEqual(dirty, committed)

            git("commit", "--allow-empty", "-qm", "Advance HEAD")
            self.assertNotEqual(committed, fingerprint())
            stable = fingerprint()
            (root / "dist/build-log").write_text("ignored output\n")
            self.assertEqual(stable, fingerprint())

    def test_state_write_is_readable_and_replaces_old_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary) / "state/component.json"
            first = {"schemaVersion": build_cache.SCHEMA_VERSION, "fingerprint": "one"}
            second = {"schemaVersion": build_cache.SCHEMA_VERSION, "fingerprint": "two"}
            build_cache.write_state(state, first)
            self.assertEqual(first, build_cache.read_state(state))
            build_cache.write_state(state, second)
            self.assertEqual(second, build_cache.read_state(state))

    def wrapper(self, root: Path, mode: str, *, force: bool = False) -> list[str]:
        return [
            sys.executable,
            "-c",
            FAKE_COMPONENT,
            str(REPOSITORY / "scripts/build-cache.py"),
            "--root",
            str(root),
            "--state-dir",
            str(root / ".build/state"),
            *(["--force"] if force else []),
            "runtime",
            "--",
            sys.executable,
            "-c",
            FAKE_BUILDER,
            str(root),
            mode,
        ]

    def test_cached_runner_skips_rebuilds_and_never_stamps_bad_builds(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.prepare_fake_component(root)
            state = root / ".build/state/runtime.json"

            def invoke(mode: str = "good", *, force: bool = False) -> subprocess.CompletedProcess:
                return subprocess.run(
                    self.wrapper(root, mode, force=force),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    env={**os.environ, "OMARCHY_FORCE_BUILD": "0"},
                )

            def count() -> str:
                return (root / "build-count").read_text().strip()

            invoke()
            self.assertEqual("1", count())
            self.assertTrue(state.is_file())
            invoke()
            self.assertEqual("1", count())
            (root / "input/build.input").write_text("edited\n")
            invoke()
            self.assertEqual("2", count())
            invoke(force=True)
            self.assertEqual("3", count())
            (root / "out/artifact").write_text("tampered\n")
            invoke()
            self.assertEqual("4", count())

            failed = invoke("fail")
            self.assertNotEqual(0, failed.returncode)
            self.assertIn("exit status 23", failed.stdout)
            self.assertFalse(state.exists())
            invoke()
            self.assertTrue(state.is_file())
            mutated = invoke("mutate")
            self.assertNotEqual(0, mutated.returncode)
            self.assertIn("inputs changed", mutated.stdout)
            self.assertFalse(state.exists())

    def test_concurrent_builds_share_the_component_lock(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.prepare_fake_component(root)
            env = {**os.environ, "OMARCHY_FORCE_BUILD": "0"}
            first = subprocess.Popen(
                self.wrapper(root, "slow"), stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, text=True, env=env,
            )
            second = subprocess.Popen(
                self.wrapper(root, "slow"), stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, text=True, env=env,
            )
            first_output, _ = first.communicate(timeout=10)
            second_output, _ = second.communicate(timeout=10)
            self.assertEqual(0, first.returncode, first_output)
            self.assertEqual(0, second.returncode, second_output)
            self.assertEqual("1", (root / "build-count").read_text().strip())
            combined = first_output + second_output
            self.assertEqual(1, combined.count("recorded successful runtime build"))
            self.assertEqual(1, combined.count("runtime is up to date"))

if __name__ == "__main__":
    unittest.main()
