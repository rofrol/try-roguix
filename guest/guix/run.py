#!/usr/bin/env python3
"""Boot a development Guix EFI image on the existing accelerated QEMU runtime.

This ephemeral smoke test is removed when the app's Guix boot/storage contract
is integrated. It must not open an existing application VM workspace.
"""

import argparse
import os
from pathlib import Path
import platform
import shlex
import subprocess


ROOT = Path(__file__).resolve().parents[2]
QEMU = ROOT / "macos/.build/qemu-gpu-runtime/bin/qemu-system-aarch64"


def qemu_command(image, firmware):
    # QEMU's legacy -drive grammar escapes literal commas by doubling them.
    # -snapshot creates a disposable overlay; the supplied raw disk stays intact.
    disk = str(image).replace(",", ",,")
    return [
        str(QEMU), "-name", "Try Guix — development",
        "-machine", "virt,accel=hvf,gic-version=3",
        "-cpu", "host,pmu=off", "-smp", "4", "-m", "4096M",
        "-nodefaults", "-action", "reboot=reset,shutdown=poweroff",
        "-bios", str(firmware),
        "-drive", f"if=none,id=root,file={disk},format=raw,media=disk",
        "-snapshot", "-device", "virtio-blk-pci,drive=root",
        "-device", "virtio-gpu-gl-pci,max_outputs=1,xres=1600,yres=900,romfile=",
        "-display", "cocoa,gl=es,show-cursor=on,zoom-to-fit=on,full-screen=off,full-grab=off,immersive=off,swap-opt-cmd=off",
        "-device", "virtio-keyboard-pci,romfile=",
        "-device", "virtio-tablet-pci,romfile=",
        "-device", "virtio-rng-pci",
        "-netdev", "user,id=net", "-device", "virtio-net-pci,netdev=net,romfile=",
        "-serial", "none", "-monitor", "none",
        "-device", "virtio-serial-pci,id=console",
        "-chardev", "stdio,id=hvc0,signal=off",
        "-device", "virtconsole,bus=console.0,chardev=hvc0",
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", type=Path, default=ROOT / "dist/guix/image.raw")
    parser.add_argument("--firmware", type=Path, required=True,
                        help="trusted AArch64 UEFI firmware (not bundled with the runtime)")
    parser.add_argument("--dry-run", action="store_true",
                        help="print the command without opening the image or starting QEMU")
    args = parser.parse_args()
    # Absolute paths also prevent a caller's filename from becoming an option.
    image = args.image.absolute()
    firmware = args.firmware.absolute()
    command = qemu_command(image, firmware)
    if args.dry_run:
        print(shlex.join(command))
        return
    try:
        if platform.system() != "Darwin" or platform.machine() != "arm64":
            raise ValueError("requires an Apple Silicon Mac")
        for path in (QEMU, image, firmware):
            if not path.is_file():
                raise ValueError(f"Required file is missing: {path}")
        # Reuse the built runtime, never silently fall back to a system QEMU.
        subprocess.run(["codesign", "--verify", "--strict", str(QEMU)], check=True)
        os.execv(str(QEMU), command)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"guix-smoke: {error}\n")


if __name__ == "__main__":
    main()
