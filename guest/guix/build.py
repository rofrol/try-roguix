#!/usr/bin/env python3
"""Build the development Guix image using the pinned local Git channel."""

import argparse
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import tempfile


HERE = Path(__file__).resolve().parent
# `git rev-parse --local-env-vars`; a test keeps this in sync with installed Git.
GIT_LOCAL_ENV_VARS = frozenset({
    "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CONFIG", "GIT_CONFIG_PARAMETERS",
    "GIT_CONFIG_COUNT", "GIT_OBJECT_DIRECTORY", "GIT_DIR", "GIT_WORK_TREE",
    "GIT_IMPLICIT_WORK_TREE", "GIT_GRAFT_FILE", "GIT_INDEX_FILE",
    "GIT_NO_REPLACE_OBJECTS", "GIT_REPLACE_REF_BASE", "GIT_PREFIX",
    "GIT_INTERNAL_SUPER_PREFIX", "GIT_SHALLOW_FILE", "GIT_COMMON_DIR",
})


def git_environment():
    """Return the environment without repository-selecting Git variables.

    An inherited GIT_DIR or GIT_WORK_TREE would make `git -C SOURCE` inspect a
    different repository than SOURCE, silently defeating the pin check.
    """
    return {k: v for k, v in os.environ.items() if k not in GIT_LOCAL_ENV_VARS}
# The Guix pin, shared with the image (/etc/roguix/guix-commit) and the
# roguix channel, which must build on the same Guix.
COMMIT = (Path(__file__).resolve().parent
          / "modules/roguix/guix-commit").read_text().strip()


def build(args):
    source = args.source.resolve(strict=True)
    env = git_environment()
    # Git channels consume committed files, not a working-tree overlay.  Refuse
    # tracked edits rather than silently build something other than the source.
    head = subprocess.check_output(
        ["git", "-C", str(source), "rev-parse", "HEAD"], text=True, env=env
    ).strip()
    if head != COMMIT:
        raise ValueError(f"Guix checkout must be pinned to {COMMIT}; found {head}")
    changes = subprocess.check_output(
        ["git", "-C", str(source), "status", "--porcelain", "--untracked-files=no"],
        text=True, env=env,
    )
    if changes:
        raise ValueError("Guix checkout has tracked changes; commit and review a new pin first")

    # Guix authenticates signatures using a 'keyring' branch advertised by the
    # channel. A normal vendor clone only has origin/keyring, which a local
    # fetch does not advertise. Export it in a disposable bare repository,
    # never by adding refs to the supplied checkout.
    keyring = subprocess.check_output(
        ["git", "-C", str(source), "rev-parse", "--verify",
         "refs/remotes/origin/keyring^{commit}"], text=True, env=env,
    ).strip()
    output = args.output.absolute()
    if not args.check and os.path.lexists(output):
        raise ValueError(f"Output already exists; choose a new --output: {output}")
    command = [
        "guix", "time-machine", "--channels=CHANNELS", "--", "system", "image",
        f"--load-path={HERE / 'modules'}",
        "--system=aarch64-linux", "--image-type=efi-raw", "--image-size=12G",
        f"--root={output}", str(HERE / "system.scm"),
    ]
    if args.check:
        command.remove(f"--root={output}")
        command.insert(-1, "--dry-run")
    if args.dry_run:
        print(f"Authenticated local channel: {source} at {COMMIT}")
        print(f"Keyring: {keyring}; official Guix introduction retained")
        print(shlex.join(command))
        return

    if platform.system() != "Linux":
        raise ValueError("Build on Linux with Guix and a running guix-daemon; macOS cannot build this image directly")
    if not shutil.which("guix"):
        raise ValueError("guix is required")
    with tempfile.TemporaryDirectory(prefix="roguix-channel-") as directory:
        channel_source = Path(directory) / "source.git"
        subprocess.run(
            ["git", "clone", "--quiet", "--bare", "--shared", str(source),
             str(channel_source)], check=True, env=env,
        )
        subprocess.run(
            ["git", "-C", str(channel_source), "update-ref", "refs/heads/keyring",
             keyring], check=True, env=env,
        )
        channels = Path(directory) / "channels.scm"
        channels.write_text(
            "(use-modules (guix channels))\n"
            "(list (channel (inherit %default-guix-channel)\n"
            f"  (url {json.dumps(channel_source.as_uri())})\n"
            f"  (commit \"{COMMIT}\")))\n"
        )
        command[2] = f"--channels={channels}"
        if not args.check:
            output.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(command, check=True, env=env)
    if args.check:
        print("Guix image evaluation succeeded; no image was built")
    else:
        print(f"Guix image GC root: {output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path,
                        default=HERE.parents[2] / "vendor/guix")
    parser.add_argument("--output", type=Path,
                        default=HERE.parents[1] / "dist/guix/image.raw")
    parser.add_argument("--dry-run", action="store_true",
                        help="print the plan without running Guix")
    parser.add_argument("--check", action="store_true",
                        help="run pinned Guix to evaluate the image without building it")
    args = parser.parse_args()
    try:
        build(args)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"guix-image: {error}\n")


if __name__ == "__main__":
    main()
