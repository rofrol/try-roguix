#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: macos/run-qemu-gpu.sh [--ephemeral | --reset-storage | --reset-storage-only] [GUEST_DIR]" >&2
  exit 64
}

fail() {
  echo "run-qemu-gpu: $*" >&2
  exit 1
}

storage_mode=persistent
reset_only=0
# QEMU 11's HVF backend requires Apple's in-hypervisor GICv3.
qemu_machine='virt,accel=hvf,gic-version=3'

case ${1:-} in
  --ephemeral)
    storage_mode=ephemeral
    shift
    ;;
  --reset-storage)
    storage_mode=reset
    shift
    ;;
  --reset-storage-only)
    storage_mode=reset
    reset_only=1
    shift
    ;;
  --*) usage ;;
esac
(( $# <= 1 )) || usage

script_dir=$(cd "$(dirname "$0")" && pwd -P)
resources_dir=$(cd "$script_dir/.." && pwd -P)
contents_dir=$(cd "$resources_dir/.." && pwd -P)
app_bundle=$(cd "$contents_dir/.." && pwd -P)
guest_input=${1:-"$resources_dir/guest"}
qemu_bin="$resources_dir/runtime/bin/Try Roguix"
native_bridge="$contents_dir/MacOS/omarchy-vm-helper"
storage_library="$script_dir/qemu-persistent-storage.sh"
port_forwarding_library="$script_dir/qemu-port-forwarding.sh"

[[ $(uname -m) == arm64 ]] || fail "requires an ARM64 Mac"
[[ $(uname -s) == Darwin ]] || fail "requires macOS"
macos_major=$(sw_vers -productVersion | cut -d. -f1)
[[ $macos_major =~ ^[0-9]+$ ]] && (( macos_major >= 15 )) || \
  fail "requires macOS 15 or newer"
[[ -d $guest_input && ! -L $guest_input ]] || fail "ARM guest directory is missing or unsafe: $guest_input"
guest_dir=$(cd "$guest_input" && pwd -P)
# The Roguix guest (guest/guix/package.py) is a UEFI/GPT disk booted by the
# runtime's EDK2 firmware.
uefi_boot_abi=uefi-gpt-v1
qemu_window_name='Try Roguix'
uefi_firmware="$resources_dir/runtime/share/qemu/edk2-aarch64-code.fd"

for command in codesign file getconf id mktemp plutil ps sysctl; do
  command -v "$command" >/dev/null || fail "$command is required"
done

case ${OMARCHY_QEMU_GPU_INSPECT_ONLY:-0} in
  0)
    codesign --verify --deep --strict "$app_bundle" >/dev/null 2>&1 || {
      fail "the installed app is damaged or has an invalid code signature"
    }
    ;;
  1) ;;
  *) fail "OMARCHY_QEMU_GPU_INSPECT_ONLY must be 0 or 1" ;;
esac

[[ -f $qemu_bin && -x $qemu_bin ]] || {
  fail "missing bundled GPU QEMU runtime at $qemu_bin"
}
[[ -f $native_bridge && -x $native_bridge ]] || {
  fail "missing bundled native bridge at $native_bridge"
}
[[ -f $uefi_firmware && ! -L $uefi_firmware ]] || {
  fail "missing bundled UEFI firmware; run make runtime"
}
file "$qemu_bin" | grep 'arm64' >/dev/null || fail "staged QEMU is not an ARM64 executable"
LC_ALL=C grep -aFq 'TryRoguix.icns' "$qemu_bin" || {
  fail "staged QEMU lacks the Try Roguix macOS identity; run make runtime"
}
for marker in \
  OMARCHY_SDL_AUDIO_CONTROL_DIRECTORY \
  OMARCHY_SDL_INPUT_DEVICE_NAME \
  OMARCHY_SDL_OUTPUT_DEVICE_NAME; do
  LC_ALL=C grep -aFq "$marker" "$qemu_bin" || {
    fail "staged QEMU lacks persistent host audio routing; run make runtime"
  }
done
file "$native_bridge" | grep 'arm64' >/dev/null || fail "native bridge is not an ARM64 executable"
codesign --verify --strict "$native_bridge" >/dev/null 2>&1 || {
  fail "native bridge is not code-signed"
}

# Search captured help directly: grep -q may close a pipe early and make
# its producer fail with SIGPIPE under pipefail, even when the match succeeds.
qemu_accels=$("$qemu_bin" -accel help 2>&1) || fail "cannot inspect staged QEMU accelerators"
grep -qx 'hvf' <<<"$qemu_accels" || fail "staged QEMU does not support HVF"
qemu_machines=$("$qemu_bin" -machine help 2>&1) || fail "cannot inspect staged QEMU machines"
grep -Eq '^virt[[:space:]]' <<<"$qemu_machines" || fail "staged QEMU does not provide the ARM virt machine"
qemu_cpus=$("$qemu_bin" -cpu help 2>&1) || fail "cannot inspect staged QEMU CPUs"
grep -Eq '^[[:space:]]*host([[:space:]]|$)' <<<"$qemu_cpus" || fail "staged QEMU does not expose the host CPU"
qemu_displays=$("$qemu_bin" -display help 2>&1) || fail "cannot inspect staged QEMU displays"
grep -qx 'cocoa' <<<"$qemu_displays" || fail "staged QEMU does not provide the Cocoa display"
qemu_devices=$("$qemu_bin" -device help 2>&1) || fail "cannot inspect staged QEMU devices"
qemu_help=$("$qemu_bin" -help 2>&1) || fail "cannot inspect staged QEMU options"
grep -q -- '^-add-fd fd=fd,set=set' <<<"$qemu_help" || {
  fail "staged QEMU cannot preserve the persistent-disk lock descriptor"
}
grep -Fq -- '-action reboot=reset|shutdown' <<<"$qemu_help" || {
  fail "staged QEMU cannot apply the required reboot policy"
}
grep -Fq -- '-action shutdown=poweroff|pause' <<<"$qemu_help" || {
  fail "staged QEMU cannot apply the required shutdown policy"
}
grep -Fq 'full-grab=on|off' <<<"$qemu_help" || {
  fail "staged QEMU cannot capture macOS system key combinations"
}
grep -Fq 'immersive=on|off' <<<"$qemu_help" || {
  fail "staged QEMU cannot select its fullscreen presentation"
}
qemu_netdevs=$("$qemu_bin" -machine virt -netdev help 2>&1) || {
  fail "cannot inspect staged QEMU network backends"
}
grep -qx 'user' <<<"$qemu_netdevs" || {
  fail "staged QEMU does not provide no-root SLIRP networking; run make runtime"
}
qemu_audiodevs=$("$qemu_bin" -machine virt -audiodev help 2>&1) || {
  fail "cannot inspect staged QEMU audio backends"
}
grep -qx 'sdl' <<<"$qemu_audiodevs" || {
  fail "staged QEMU does not provide duplex SDL audio; run make runtime"
}

require_qemu_device() {
  local device=$1
  [[ $qemu_devices == *"name \"$device\""* ]] || fail "staged QEMU does not provide $device"
}

for device in \
  hda-micro \
  intel-hda \
  virtconsole \
  virtserialport \
  virtio-balloon-pci \
  virtio-9p-pci \
  virtio-blk-pci \
  virtio-gpu-gl-pci \
  virtio-keyboard-pci \
  virtio-net-pci \
  virtio-rng-pci \
  virtio-serial-pci \
  virtio-tablet-pci \
  virtio-pinch-pci \
  qemu-xhci \
  usb-kbd; do
  require_qemu_device "$device"
done
for marker in guest_owner_uid guest_owner_gid; do
  LC_ALL=C grep -aFq "$marker" "$qemu_bin" || {
    fail "staged QEMU lacks the shared-folder owner mapping; run make runtime"
  }
done
for marker in hv_vm_config_set_el2_enabled hv_gic_create; do
  LC_ALL=C grep -aFq "$marker" "$qemu_bin" || {
    fail "staged QEMU lacks HVF nested virtualization; run make runtime"
  }
done
LC_ALL=C grep -aFq 'HVF free-page backing replacement failed' "$qemu_bin" || {
  fail "staged QEMU lacks macOS memory reclamation; run make runtime"
}

qemu_entitlements=$(codesign -d --entitlements - "$qemu_bin" 2>&1) || {
  fail "staged QEMU is not code-signed for HVF"
}
[[ $qemu_entitlements == *com.apple.security.hypervisor* ]] || {
  fail "staged QEMU lacks the com.apple.security.hypervisor entitlement"
}

gpu_help=$("$qemu_bin" -device virtio-gpu-gl-pci,help 2>&1) || {
  fail "cannot inspect the staged VirGL device"
}
gpu_device='virtio-gpu-gl-pci,max_outputs=1,xres=1920,yres=1080'
if [[ $gpu_help == *'romfile=<str>'* ]]; then
  gpu_device+=',romfile='
fi

# Release apps carry the output of this strict validator in their signed
# resources, so a clean Mac does not need Python. Repo-local development
# bundles can still validate directly when no launch configuration is present.
launch_configuration="$guest_dir/launch.plist"
launch_boot_abi=''
if [[ -f $launch_configuration && ! -L $launch_configuration ]]; then
  plist_read() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$launch_configuration" 2>/dev/null
  }
  bundle_validation=$(printf '%s\t%s\t%s\t%s\t%s\t%s' \
    "$(plist_read bundleIdentity)" \
    "$(plist_read sourceDiskSHA256)" \
    "$(plist_read sourceDiskBytes)" \
    "$(plist_read compressedDiskBytes)" \
    "$(plist_read workingDiskBytes)" \
    "$(plist_read guestLocales || printf -)")
  launch_boot_abi=$(plist_read bootABI || true)
  # Release apps ship without the compressed disk and download it instead
  # (qemu_persistent_storage_fetch_compressed_source).
  disk_download_base=$(plist_read diskDownloadBase || true)
  disk_download_part_bytes=$(plist_read diskDownloadPartBytes || true)
  compressed_disk_sha=$(plist_read compressedDiskSHA256 || true)
else
  [[ -e $guest_dir/guix-manifest.json && ! -L $guest_dir/guix-manifest.json ]] || {
    fail "the guest directory is not a packaged Roguix guest: $guest_dir"
  }
  command -v python3 >/dev/null 2>&1 || {
    fail "bundled launch configuration is missing and Python is unavailable for development validation"
  }
  # guix-artifact.py checks the exact file set, manifest, GPT layout record and
  # every checksum, then prints the launch record.
  bundle_validation=$(python3 "$script_dir/guix-artifact.py" launch-record "$guest_dir") || {
    fail "the bundled Roguix guest failed validation"
  }
  launch_boot_abi=$uefi_boot_abi
fi
IFS=$'\t' read -r bundle_identity source_disk_sha source_disk_bytes compressed_disk_bytes \
  expanded_disk_bytes guest_locales \
  <<<"$bundle_validation"
[[ $guest_locales =~ ^(-|[A-Za-z0-9_.-]+(,[A-Za-z0-9_.-]+)*)$ ]] || \
  fail "validated guest locales are invalid"
[[ $bundle_identity =~ ^[0-9a-f]{64}$ ]] || fail "validated bundle identity is invalid"
[[ $source_disk_sha =~ ^[0-9a-f]{64}$ ]] || fail "validated disk digest is invalid"
[[ $source_disk_bytes =~ ^[1-9][0-9]*$ ]] || fail "validated disk size is invalid"
[[ $compressed_disk_bytes =~ ^[1-9][0-9]*$ ]] || fail "validated compressed disk size is invalid"
[[ $expanded_disk_bytes =~ ^[1-9][0-9]*$ ]] || fail "validated working-disk size is invalid"
(( expanded_disk_bytes >= source_disk_bytes )) || fail "working disk cannot be smaller than its source"
[[ $launch_boot_abi == "$uefi_boot_abi" ]] || fail "the guest does not declare the UEFI boot ABI"
if [[ ${OMARCHY_QEMU_GPU_INSPECT_ONLY:-0} == 1 ]]; then
  printf '%s\n' "$bundle_validation"
  exit 0
fi

[[ -f $storage_library && ! -L $storage_library ]] || {
  fail "persistent-storage library is missing or unsafe: $storage_library"
}
[[ -f $port_forwarding_library && ! -L $port_forwarding_library ]] || {
  fail "port-forwarding library is missing or unsafe: $port_forwarding_library"
}

# These libraries are sealed resources in normal app launches. The complete
# app bundle was verified above before either file can execute. Inspect-only is
# a build-time path and exits without sourcing any shell library.
# shellcheck source=qemu-persistent-storage.sh
source "$storage_library"
QEMU_PERSISTENT_STORAGE_HELPER=$native_bridge
# shellcheck source=qemu-port-forwarding.sh
source "$port_forwarding_library"
source "$script_dir/qemu-networking.sh"
qemu_network_validate
if [[ $QEMU_NETWORK_MODE == bridged ]]; then
  grep -qx stream <<<"$qemu_netdevs" || fail 'The bundled QEMU does not support bridged networking. Rebuild the runtime.'
fi

network_forwards=${OMARCHY_QEMU_GPU_PORT_FORWARDS:-}
[[ $QEMU_NETWORK_MODE == nat ]] || network_forwards=
if ! qemu_port_forwarding_configure "$network_forwards"; then
  fail "$QEMU_PORT_FORWARDING_ERROR"
fi
qemu_netdev=$QEMU_PORT_FORWARDING_NETDEV
port_forwarding_summary=$QEMU_PORT_FORWARDING_SUMMARY
ssh_setting=''
if ((QEMU_PORT_FORWARDING_ENABLES_SSH)); then
  ssh_setting='tryomarchy.ssh_access=1'
fi
if [[ $QEMU_NETWORK_MODE == bridged && $QEMU_NETWORK_SSH == 1 ]]; then
  ssh_setting='tryomarchy.ssh_access=1'
fi

keyboard_setting=''
if ((reset_only)); then
  unset TRYOMARCHY_KEYBOARD
else
  host_keyboard_geometry=$("$native_bridge" --host-keyboard-geometry) || {
    fail "cannot detect the host Mac keyboard geometry"
  }
  case "$host_keyboard_geometry" in
    ansi|iso|jis) ;;
    *)
      fail "host Mac keyboard geometry is invalid: $host_keyboard_geometry"
      ;;
  esac
  keyboard_setting="tryomarchy.keyboard=$host_keyboard_geometry"
  export TRYOMARCHY_KEYBOARD=$host_keyboard_geometry
fi

# First-start suggestions for roguix-setup: the Mac's time zone and keyboard
# layout. Only layouts roguix-setup offers are named; others suggest US.
mac_setup_settings=''
mac_timezone=$(readlink /etc/localtime 2>/dev/null | sed -n 's|^.*/zoneinfo/||p')
if [[ $mac_timezone =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]]; then
  mac_setup_settings="tryomarchy.timezone=$(printf '%s' "$mac_timezone" | base64 | tr '+/' '-_' | tr -d '=\n')"
fi
mac_layout_variant=''
case $(defaults read com.apple.HIToolbox AppleCurrentKeyboardLayoutInputSourceID 2>/dev/null) in
  com.apple.keylayout.US|com.apple.keylayout.ABC) mac_layout=us ;;
  com.apple.keylayout.USInternational-PC) mac_layout=us mac_layout_variant=intl ;;
  com.apple.keylayout.British|com.apple.keylayout.British-PC) mac_layout=gb ;;
  com.apple.keylayout.Dvorak) mac_layout=us mac_layout_variant=dvorak ;;
  com.apple.keylayout.Colemak) mac_layout=us mac_layout_variant=colemak ;;
  com.apple.keylayout.Belgian) mac_layout=be ;;
  com.apple.keylayout.Brazilian*) mac_layout=br ;;
  com.apple.keylayout.Croatian*) mac_layout=hr ;;
  com.apple.keylayout.Czech*) mac_layout=cz ;;
  com.apple.keylayout.Danish) mac_layout=dk ;;
  com.apple.keylayout.Dutch) mac_layout=nl ;;
  com.apple.keylayout.Estonian) mac_layout=ee ;;
  com.apple.keylayout.Finnish*) mac_layout=fi ;;
  com.apple.keylayout.French|com.apple.keylayout.French-PC|com.apple.keylayout.French-numerical) mac_layout=fr ;;
  com.apple.keylayout.Canadian-CSA|com.apple.keylayout.Canadian) mac_layout=ca ;;
  com.apple.keylayout.SwissFrench) mac_layout=ch mac_layout_variant=fr ;;
  com.apple.keylayout.German) mac_layout=de ;;
  com.apple.keylayout.SwissGerman) mac_layout=ch ;;
  com.apple.keylayout.Greek*) mac_layout=gr ;;
  com.apple.keylayout.Hungarian*) mac_layout=hu ;;
  com.apple.keylayout.Icelandic) mac_layout=is ;;
  com.apple.keylayout.Irish*) mac_layout=ie ;;
  com.apple.keylayout.Italian*) mac_layout=it ;;
  com.apple.keylayout.Latvian) mac_layout=lv ;;
  com.apple.keylayout.Lithuanian) mac_layout=lt ;;
  com.apple.keylayout.Norwegian*) mac_layout=no ;;
  com.apple.keylayout.Polish|com.apple.keylayout.PolishPro) mac_layout=pl ;;
  com.apple.keylayout.Portuguese) mac_layout=pt ;;
  com.apple.keylayout.Romanian*) mac_layout=ro ;;
  com.apple.keylayout.Russian*) mac_layout=ru ;;
  com.apple.keylayout.Serbian-Latin) mac_layout=rs mac_layout_variant=latin ;;
  com.apple.keylayout.Slovak*) mac_layout=sk ;;
  com.apple.keylayout.Slovenian) mac_layout=si ;;
  com.apple.keylayout.Spanish*) mac_layout=es ;;
  com.apple.keylayout.LatinAmerican) mac_layout=latam ;;
  com.apple.keylayout.Swedish*) mac_layout=se ;;
  com.apple.keylayout.Turkish*) mac_layout=tr ;;
  com.apple.keylayout.Ukrainian*) mac_layout=ua ;;
  *) mac_layout=us ;;
esac
mac_setup_settings+=" tryomarchy.keyboard_layout=$mac_layout"
[[ -z $mac_layout_variant ]] || mac_setup_settings+=" tryomarchy.keyboard_variant=$mac_layout_variant"

host_cpu_count=$(
  sysctl -n hw.logicalcpu 2>/dev/null ||
    sysctl -n hw.ncpu 2>/dev/null ||
    getconf _NPROCESSORS_ONLN 2>/dev/null
) || {
  fail "cannot determine the host CPU count"
}
[[ $host_cpu_count =~ ^[1-9][0-9]{0,6}$ ]] || fail "host CPU count is invalid: $host_cpu_count"
(( host_cpu_count >= 4 )) || fail "the ARM guest requires at least four host CPUs"
default_vcpu_count=8
if (( host_cpu_count < default_vcpu_count )); then
  default_vcpu_count=$host_cpu_count
fi
# Capacity is independent of the signed factory metrics. Validate before any
# workspace mutation; a blank setting preserves existing/factory capacity.
disk_capacity_gib=${OMARCHY_QEMU_GPU_DISK_GIB:-}
disk_capacity_bytes=''
if [[ -n $disk_capacity_gib ]]; then
  [[ $disk_capacity_gib =~ ^[1-9][0-9]{0,3}$ ]] && (( disk_capacity_gib <= 8192 )) || \
    fail "OMARCHY_QEMU_GPU_DISK_GIB must be a whole number from 1 to 8192"
  disk_capacity_bytes=$((disk_capacity_gib * 1024 * 1024 * 1024))
fi

vcpu_count=${OMARCHY_QEMU_GPU_CPUS-$default_vcpu_count}
# Bound and validate decimal text before shell arithmetic: reject expressions,
# leading zeroes (octal), and values that could wrap a signed integer.
[[ $vcpu_count =~ ^[1-9][0-9]{0,6}$ ]] || fail "OMARCHY_QEMU_GPU_CPUS must be a whole number in canonical decimal"
(( vcpu_count >= 4 && vcpu_count <= host_cpu_count )) || {
  fail "OMARCHY_QEMU_GPU_CPUS must be between 4 and $host_cpu_count"
}

# Match the app's host-aware default and independently validate scripted
# allocations. The guest manifest's 4096 MiB recommendation is the baseline;
# Macs with at least 16 GiB default to 8 GiB. Keep 4 GiB for macOS above the
# baseline, while retaining support for smaller hosts such as CI runners.
host_memory_bytes=$(sysctl -n hw.memsize 2>/dev/null) || fail "cannot determine the host memory size"
[[ $host_memory_bytes =~ ^[1-9][0-9]{0,17}$ ]] || fail "host memory size is invalid: $host_memory_bytes"
host_memory_mib=$((host_memory_bytes / 1048576))
default_memory_mib=4096
if (( host_memory_mib >= 16384 )); then
  default_memory_mib=8192
fi
memory_mib=${OMARCHY_QEMU_GPU_MEMORY_MIB:-$default_memory_mib}
# Seven digits bound the value below any real host while keeping the
# arithmetic far from 64-bit wraparound; forcing base 10 stops bash from
# reading a leading zero as octal while QEMU would read the same string as
# decimal.
[[ $memory_mib =~ ^[0-9]{1,7}$ ]] || fail "OMARCHY_QEMU_GPU_MEMORY_MIB must be a whole number of MiB"
memory_mib=$((10#$memory_mib))
(( memory_mib >= 2048 )) || fail "the ARM guest requires at least 2048 MiB of memory"
if (( memory_mib > 4096 )); then
  (( memory_mib + 4096 <= host_memory_mib )) || {
    fail "OMARCHY_QEMU_GPU_MEMORY_MIB must leave the host at least 4096 MiB (host has ${host_memory_mib} MiB)"
  }
fi
if (( memory_mib % 1024 == 0 )); then
  memory_display="$((memory_mib / 1024)) GiB"
else
  memory_display="${memory_mib} MiB"
fi

# The launcher publishes one optional Mac folder for the guest. The Swift app
# canonicalizes and validates the selection first; re-check here so a stray
# environment value can never export an unsafe tree. Empty means disabled.
shared_folder=${OMARCHY_QEMU_GPU_SHARED_FOLDER:-}
shared_folder_mount_tag=mac
shared_folder_guest_owner_uid=1000
shared_folder_guest_owner_gid=1000
shared_folder_setting=""
if [[ -n $shared_folder ]]; then
  [[ $shared_folder == /* ]] || fail "shared folder must be an absolute path"
  [[ $shared_folder != *$'\n'* && $shared_folder != *$'\r'* && $shared_folder != *,* ]] || {
    fail "shared folder path contains an unsupported character"
  }
  [[ -d $shared_folder && ! -L $shared_folder ]] || {
    fail "shared folder is missing or is a symbolic link: $shared_folder"
  }
  shared_folder=$(cd "$shared_folder" && pwd -P) || fail "cannot resolve the shared folder"
  # A symlink in the middle of the path can resolve to a name that the first
  # check never saw, so validate the canonical path again before it goes into
  # QEMU's comma-delimited -fsdev option.
  [[ $shared_folder == /* && -d $shared_folder && ! -L $shared_folder ]] || {
    fail "shared folder resolves outside a plain directory: $shared_folder"
  }
  [[ $shared_folder != *$'\n'* && $shared_folder != *$'\r'* && $shared_folder != *,* ]] || {
    fail "shared folder resolves to a path with an unsupported character: $shared_folder"
  }
  [[ $(_qps_owner "$shared_folder") == $(id -u) ]] || {
    fail "shared folder must be owned by this user: $shared_folder"
  }
  home_dir=$(cd "$HOME" 2>/dev/null && pwd -P || true)
  case "$shared_folder" in
    /|/Users|/private|/private/tmp|/tmp|/System|/Library|/Applications|/Volumes)
      fail "refusing to share a system directory: $shared_folder"
      ;;
  esac
  if [[ -n $home_dir ]]; then
    [[ $shared_folder != "$home_dir" ]] || fail "refusing to share the whole home folder"
    [[ $shared_folder != "$home_dir/Library" && $shared_folder != "$home_dir/Library/"* ]] || {
      fail "refusing to share the Library folder"
    }
  fi
  # The guest links ~/<name> to the mount so a shared ~/Work appears as ~/Work.
  # The name travels as a launcher setting in URL-safe base64, which keeps
  # spaces and non-ASCII names intact inside one space-free value.
  shared_folder_name=${shared_folder##*/}
  [[ -n $shared_folder_name && $shared_folder_name != . && $shared_folder_name != .. ]] || {
    fail "shared folder has no usable name: $shared_folder"
  }
  shared_folder_name_encoded=$(printf '%s' "$shared_folder_name" | base64 | tr '+/' '-_' | tr -d '=\n')
  [[ $shared_folder_name_encoded =~ ^[A-Za-z0-9_-]+$ ]] || fail "cannot encode the shared folder name"
  shared_folder_setting="omarchy.shared_folder_name=$shared_folder_name_encoded"
fi

# The launcher publishes an optional guest language opt-in. The Swift app
# validates the choice against its own locale allowlist first; re-check here
# so a stray environment value can never select a locale the guest image
# never generated. Empty means the guest's own default (English).
guest_locale=${OMARCHY_QEMU_GPU_LOCALE:-}
if [[ -n $guest_locale ]]; then
  case $guest_locale in
    zh_TW.UTF-8) ;;
    *)
      fail "unsupported guest locale: $guest_locale"
      ;;
  esac
fi
# The image declares the languages it can switch to; an image without one
# (or an older VM's guest, which ignores the setting) boots in English.
locale_setting=''
if [[ -n $guest_locale ]]; then
  [[ ,$guest_locales, == *",$guest_locale,"* ]] || \
    fail 'This Roguix image does not support language selection; use English.'
  locale_setting="tryomarchy.locale=$guest_locale"
fi

work_dir=""
owner_marker=""
owner_token=""
qemu_pid=""
monitor_ready_pid=""
audio_bridge_pid=""
authentication_bridge_pid=""
camera_bridge_pid=""
battery_bridge_pid=""
clipboard_bridge_pid=""
network_link_bridge_pid=""
integration_bridge_pid=""

terminate_child() {
  local pid=$1
  local attempts=$2
  local attempt=0
  local state=""
  [[ $pid =~ ^[0-9]+$ ]] || return 0
  kill -TERM "$pid" 2>/dev/null || true
  for ((attempt = 0; attempt < attempts; attempt++)); do
    state=$(ps -p "$pid" -o state= 2>/dev/null || true)
    [[ -n $state && $state != *Z* ]] || break
    sleep 0.05
  done
  state=$(ps -p "$pid" -o state= 2>/dev/null || true)
  if [[ -n $state && $state != *Z* ]]; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
}

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  set +e
  if [[ $monitor_ready_pid =~ ^[0-9]+$ ]]; then
    terminate_child "$monitor_ready_pid" 20
  fi
  if [[ $network_link_bridge_pid =~ ^[0-9]+$ ]]; then
    terminate_child "$network_link_bridge_pid" 20
  fi
  if [[ $integration_bridge_pid =~ ^[0-9]+$ ]]; then
    terminate_child "$integration_bridge_pid" 20
  fi
  if [[ $qemu_pid =~ ^[0-9]+$ ]]; then
    terminate_child "$qemu_pid" 40
  fi
  if [[ $audio_bridge_pid =~ ^[0-9]+$ ]]; then
    terminate_child "$audio_bridge_pid" 20
  fi
  if [[ $authentication_bridge_pid =~ ^[0-9]+$ ]]; then
    terminate_child "$authentication_bridge_pid" 20
  fi
  if [[ $camera_bridge_pid =~ ^[0-9]+$ ]]; then
    terminate_child "$camera_bridge_pid" 20
  fi
  if [[ $battery_bridge_pid =~ ^[0-9]+$ ]]; then
    terminate_child "$battery_bridge_pid" 20
  fi
  if [[ $clipboard_bridge_pid =~ ^[0-9]+$ ]]; then
    terminate_child "$clipboard_bridge_pid" 20
  fi
  qemu_network_stop || status=1
  qemu_persistent_storage_release_lock
  if [[ -n $work_dir && -n $owner_marker && -n $owner_token ]]; then
    case "$work_dir" in
      /private/tmp/omarchy-qemu-gpu.??????)
        if [[ -d $work_dir && ! -L $work_dir && -f $owner_marker && ! -L $owner_marker ]] &&
           [[ $(_qps_owner "$work_dir") == $(id -u) ]] &&
           [[ $(<"$owner_marker") == "$owner_token" ]]; then
          /bin/rm -rf "$work_dir" || {
            echo "run-qemu-gpu: could not remove owned temporary directory $work_dir" >&2
          }
        else
          echo "run-qemu-gpu: refusing to remove unverified temporary directory $work_dir" >&2
        fi
        ;;
      *)
        echo "run-qemu-gpu: refusing to remove unexpected temporary path $work_dir" >&2
        ;;
    esac
  fi
  exit "$status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

reap_stale_work_dirs() {
  local process_snapshot=""
  if ! process_snapshot=$(ps -axo pid=,command= 2>/dev/null); then
    echo '[qemu-gpu] Process inspection unavailable; leaving other run directories intact.' >&2
    return 0
  fi
  local candidate=""
  local marker=""
  local marker_value=""
  local launcher_pid=""
  local launcher_command=""
  local qemu_marker=""
  local stale_qemu_pid=""
  local qemu_command=""

  for candidate in /private/tmp/omarchy-qemu-gpu.??????; do
    [[ -d $candidate && ! -L $candidate ]] || continue
    [[ $(_qps_owner "$candidate") == $(id -u) ]] || continue
    [[ $(_qps_permissions "$candidate") == 700 ]] || continue

    marker="$candidate/.run-qemu-gpu.owner"
    [[ -f $marker && ! -L $marker ]] || continue
    marker_value=$(<"$marker")
    [[ $marker_value =~ ^run-qemu-gpu:v1:([0-9]+):([0-9]+)$ ]] || continue

    launcher_pid=${BASH_REMATCH[1]}
    launcher_command=$(printf '%s\n' "$process_snapshot" | awk -v pid="$launcher_pid" '$1 == pid { $1=""; print }')
    [[ $launcher_command != *"run-qemu-gpu.sh"* ]] || continue

    stale_qemu_pid=""
    qemu_marker="$candidate/.qemu.pid"
    if [[ -f $qemu_marker && ! -L $qemu_marker ]]; then
      stale_qemu_pid=$(<"$qemu_marker")
      [[ $stale_qemu_pid =~ ^[0-9]+$ ]] || continue
      qemu_command=$(printf '%s\n' "$process_snapshot" | awk -v pid="$stale_qemu_pid" '$1 == pid { $1=""; print }')
      if [[ $qemu_command == *"$qemu_bin"* &&
            $qemu_command == *"unix:/tmp/${candidate##*/}/qmp.sock"* ]]; then
        continue
      fi
    fi

    # A failed ps is not evidence that a process exited. Obtain a complete UID
    # inventory after reading the marker, and prove it contains this launcher.
    local process_ids="" inspected_pid="" inspection_valid=0 run_is_alive=0
    if ! process_ids=$(ps -U "$(id -u)" -o pid= 2>/dev/null); then
      continue
    fi
    while read -r inspected_pid; do
      [[ $inspected_pid =~ ^[0-9]+$ ]] || continue
      [[ $inspected_pid != "$$" ]] || inspection_valid=1
      if [[ $inspected_pid == "$launcher_pid" || $inspected_pid == "$stale_qemu_pid" ]]; then
        run_is_alive=1
      fi
    done <<<"$process_ids"
    (( inspection_valid == 1 && run_is_alive == 0 )) || continue

    echo "[qemu-gpu] Removing a verified stale disposable run: $candidate" >&2
    /bin/rm -rf "$candidate"
  done
}

reap_stale_work_dirs

umask 077
work_dir=$(mktemp -d '/private/tmp/omarchy-qemu-gpu.XXXXXX') || {
  fail "could not create a private temporary directory"
}
case "$work_dir" in
  /private/tmp/omarchy-qemu-gpu.??????) ;;
  *) fail "mktemp returned an unexpected path: $work_dir" ;;
esac
[[ -d $work_dir && ! -L $work_dir ]] || fail "temporary directory is unsafe: $work_dir"
[[ $(_qps_owner "$work_dir") == $(id -u) ]] || fail "temporary directory is not owned by this user"
owner_marker="$work_dir/.run-qemu-gpu.owner"
owner_token="run-qemu-gpu:v1:$$:${RANDOM}${RANDOM}"
printf '%s\n' "$owner_token" >"$owner_marker"
chmod 600 "$owner_marker"

# Foundation's standardizedFileURL deliberately spells macOS's private
# temporary-directory alias as /tmp. Keep the owned directory's physical path
# for cleanup, but expose the runtime sockets through that standardized alias.
qmp_socket="/tmp/${work_dir##*/}/qmp.sock"
audio_bridge_socket="/tmp/${work_dir##*/}/audio.sock"
authentication_bridge_socket="/tmp/${work_dir##*/}/authentication.sock"
camera_bridge_socket="/tmp/${work_dir##*/}/camera.sock"
battery_bridge_socket="/tmp/${work_dir##*/}/battery.sock"
clipboard_bridge_socket="/tmp/${work_dir##*/}/clipboard.sock"
settings_bridge_socket="/tmp/${work_dir##*/}/settings.sock"
integration_bridge_socket="/tmp/${work_dir##*/}/integrations.sock"
audio_route_dir="/tmp/${work_dir##*/}/audio-routes"
mkdir -m 700 "$work_dir/audio-routes"

source_disk_name=disk.raw
selected_existing=0
if [[ $storage_mode == persistent ]]; then
  if qemu_persistent_storage_select_existing "$bundle_identity"; then
    selected_existing=1
  else
    storage_status=$?
    if (( storage_status == QEMU_PERSISTENT_STORAGE_INCOMPATIBLE_STATUS )); then
      exit "$storage_status"
    fi
    if (( storage_status != QEMU_PERSISTENT_STORAGE_MISSING_STATUS )); then
      fail "could not inspect the saved VM disk"
    fi
  fi
fi

if (( selected_existing == 0 )); then
  if [[ -n $disk_capacity_bytes ]]; then
    (( disk_capacity_bytes >= expanded_disk_bytes )) || fail 'maximum disk size is below the factory capacity'
    expanded_disk_bytes=$disk_capacity_bytes
  fi
  source_disk="$guest_dir/$source_disk_name"
  compressed_disk="$guest_dir/$source_disk_name.zst"
  downloaded_disk=''
  if [[ ! -e $source_disk && ! -L $source_disk && ! -e $compressed_disk &&
        -n ${disk_download_base:-} ]]; then
    qemu_persistent_storage_fetch_compressed_source \
      "$bundle_identity" \
      "$disk_download_base" \
      "$disk_download_part_bytes" \
      "$compressed_disk_bytes" \
      "$compressed_disk_sha" \
      "$source_disk_bytes" || fail "could not download the Roguix disk"
    if [[ -n $QEMU_IMMUTABLE_SOURCE_DISK ]]; then
      source_disk=$QEMU_IMMUTABLE_SOURCE_DISK
    else
      compressed_disk=$QEMU_DOWNLOADED_COMPRESSED_DISK
      downloaded_disk=$compressed_disk
    fi
  fi
  if [[ ! -e $source_disk && ! -L $source_disk ]]; then
    qemu_persistent_storage_materialize_source \
      "$bundle_identity" \
      "$compressed_disk" \
      "$compressed_disk_bytes" \
      "$source_disk_sha" \
      "$source_disk_bytes" \
      "$resources_dir/runtime/bin/zstd" || fail "could not materialize the bundled root disk"
    source_disk=$QEMU_IMMUTABLE_SOURCE_DISK
    # The expanded image replaces the download.
    [[ -z $downloaded_disk ]] || /bin/rm -f -- "$downloaded_disk"
  fi
  if qemu_persistent_storage_select \
    "$storage_mode" \
    "$bundle_identity" \
    "$source_disk" \
    "$source_disk_sha" \
    "$source_disk_bytes" \
    "$work_dir" \
    "$expanded_disk_bytes"; then
    :
  else
    storage_status=$?
    if (( storage_status == QEMU_PERSISTENT_STORAGE_INCOMPATIBLE_STATUS )); then
      exit "$storage_status"
    fi
    fail "could not prepare the selected root disk"
  fi
fi
working_disk=$QEMU_SELECTED_DISK

case ${OMARCHY_QEMU_GPU_DRY_RUN:-0} in
  0|1) ;;
  *) fail "OMARCHY_QEMU_GPU_DRY_RUN must be 0 or 1" ;;
esac
boot_args=(-bios "$uefi_firmware")
# Firmware boots the guest's own GRUB, so the launcher's settings travel as
# SMBIOS OEM strings (type 11); roguix-host-settings reads them. Each is
# name=value with a base64url or literal value, so none contains a space or
# comma.
for launcher_setting in omarchy.qemu_virgl=1 omarchy.virgl_dual_source=1 \
  $shared_folder_setting $ssh_setting $keyboard_setting $locale_setting \
  $mac_setup_settings; do
  boot_args+=(-smbios "type=11,value=$launcher_setting")
done

if ((reset_only)); then
  qemu_persistent_storage_release_lock
  echo "[qemu-gpu] Reset complete." >&2
  exit 0
fi

if [[ -n $disk_capacity_bytes && $storage_mode == persistent && ${OMARCHY_QEMU_GPU_DRY_RUN:-0} == 0 ]]; then
  qemu_persistent_storage_grow_selected "$disk_capacity_bytes" "$native_bridge" || \
    fail 'could not apply maximum disk size'
fi


case ${OMARCHY_QEMU_GPU_IMMERSIVE:-1} in
  1)
    cocoa_full_screen=on
    cocoa_immersive=on
    ;;
  0)
    cocoa_full_screen=off
    cocoa_immersive=off
    ;;
  *) fail "OMARCHY_QEMU_GPU_IMMERSIVE must be 0 or 1" ;;
esac


# macOS 15 can pass the paused EL2 probe, then abort with HV_BAD_ARGUMENT when
# QEMU synchronizes vCPU registers (#211). Keep it on the platform-GIC/EL1 path.
# On macOS 26+, probe actual Hypervisor.framework support for EL2 rather than
# guessing from a model name; older Apple Silicon still falls back to EL1.
host_macos_version=$(sw_vers -productVersion 2>/dev/null) || host_macos_version=''
host_macos_major=${host_macos_version%%.*}
qemu_virtualization_args=(-machine "$qemu_machine")
if [[ $host_macos_major =~ ^[1-9][0-9]*$ ]] && \
  (( host_macos_major >= 26 )) && \
  printf '%s\n' \
    '{"execute":"qmp_capabilities"}' \
    '{"execute":"quit"}' | \
  "$qemu_bin" \
    -machine 'virt,gic-version=3,virtualization=on' \
    -accel 'hvf,kernel-irqchip=on' \
    -cpu 'host,pmu=off' \
    -smp 1 \
    -m 128M \
    -nodefaults \
    -display none \
    -S \
    -qmp stdio >/dev/null 2>&1; then
  qemu_virtualization_args=(
    -machine 'virt,gic-version=3,virtualization=on'
    -accel 'hvf,kernel-irqchip=on'
  )
  echo '[qemu-gpu] Nested virtualization is enabled.' >&2
else
  echo '[qemu-gpu] Nested virtualization is unavailable; using the compatible EL1 path.' >&2
fi

if [[ $QEMU_SELECTED_STORAGE_MODE == persistent && -n $QEMU_PERSISTENT_STORAGE_ROOT ]]; then
  console_log="$QEMU_PERSISTENT_STORAGE_ROOT/console.log"
else
  console_log="$work_dir/console.log"
fi
if [[ -f $console_log ]]; then
  mv -f "$console_log" "$console_log.1" 2>/dev/null || true
fi
console_log_option=${console_log//,/,,}

network_mac=$(qemu_network_mac) || fail 'Cannot prepare the VM network identity.'
if [[ $QEMU_NETWORK_MODE == bridged ]]; then
  port_forwarding_summary='inactive in bridged mode'
  if [[ ${OMARCHY_QEMU_GPU_DRY_RUN:-0} == 1 ]]; then
    qemu_netdev='stream,id=omarchy-net,server=off,addr.type=unix,addr.path=/private/tmp/bridge-dry-run/network.sock'
  else
    qemu_network_start "$contents_dir/Resources" "$work_dir"
    qemu_netdev=$QEMU_NETWORK_NETDEV
  fi
fi

qemu_args=(
  -name "$qemu_window_name"
  "${qemu_virtualization_args[@]}"
  # HVF does not provide a usable guest PMU on Apple Silicon. Do not advertise
  # one: Linux otherwise probes the dead device and prints a misleading failure.
  -cpu 'host,pmu=off'
  -smp "$vcpu_count,sockets=1,cores=$vcpu_count,threads=1"
  -m "${memory_mib}M"
  -nodefaults
  # Reboot the guest inside this QEMU process, but let shutdown close the app.
  -action 'reboot=reset,shutdown=poweroff'
  -netdev "$qemu_netdev"
  -device "virtio-net-pci,id=omarchy-nic,netdev=omarchy-net,mac=$network_mac,romfile="
  -audiodev 'sdl,id=omarchy-audio'
  -device 'intel-hda,id=omarchy-hda,romfile='
  -device 'hda-micro,bus=omarchy-hda.0,audiodev=omarchy-audio'
  -serial none
  -monitor none
  -qmp "unix:$qmp_socket,server=on,wait=off"
  "${boot_args[@]}"
  -drive "if=none,id=omarchy-root,file=$working_disk,format=raw,media=disk,cache=writeback"
  -device 'virtio-blk-pci,drive=omarchy-root,serial=omarchy-root'
  -device "$gpu_device"
  # Cocoa forwards its live backing-pixel dimensions and the current host
  # display refresh rate through Virtio GPU EDID. Its accessibility-backed
  # Full grab keeps every Command chord with the focused guest in either
  # presentation mode. Immersive launches Full Screen and hard-hides the Mac
  # menu bar and Dock; otherwise Cocoa opens a centered, resizable window.
  -display "cocoa,gl=es,show-cursor=on,zoom-to-fit=on,full-screen=$cocoa_full_screen,full-grab=on,immersive=$cocoa_immersive,swap-opt-cmd=off"
  -device 'virtio-keyboard-pci,romfile='
  -device 'virtio-tablet-pci,romfile='
  -device 'virtio-pinch-pci,romfile='
  -object 'rng-random,id=omarchy-rng,filename=/dev/urandom'
  -device 'virtio-rng-pci,rng=omarchy-rng'
  # Report genuinely free pages without reducing the guest RAM allocation.
  -device virtio-balloon-pci,free-page-reporting=on
  -device 'virtio-serial-pci,id=omarchy-serial'
  -chardev "socket,id=omarchy-settings-bridge,path=$settings_bridge_socket,server=on,wait=off"
  -device 'virtserialport,bus=omarchy-serial.0,nr=6,chardev=omarchy-settings-bridge,name=dev.tryomarchy.settings'
  -chardev "stdio,id=omarchy-hvc0,signal=off,logfile=$console_log_option,logappend=off"
  -device 'virtconsole,bus=omarchy-serial.0,nr=0,chardev=omarchy-hvc0'
  -chardev "socket,id=omarchy-audio-bridge,path=$audio_bridge_socket,server=on,wait=off"
  -device 'virtserialport,bus=omarchy-serial.0,nr=1,chardev=omarchy-audio-bridge,name=dev.tryomarchy.audio'
  -chardev "socket,id=omarchy-clipboard-bridge,path=$clipboard_bridge_socket,server=on,wait=off"
  -device 'virtserialport,bus=omarchy-serial.0,nr=2,chardev=omarchy-clipboard-bridge,name=dev.tryomarchy.clipboard'
  -chardev "socket,id=omarchy-authentication-bridge,path=$authentication_bridge_socket,server=on,wait=off"
  -device 'virtserialport,bus=omarchy-serial.0,nr=3,chardev=omarchy-authentication-bridge,name=dev.tryomarchy.authentication'
  -chardev "socket,id=omarchy-camera-bridge,path=$camera_bridge_socket,server=on,wait=off"
  -device 'virtserialport,bus=omarchy-serial.0,nr=4,chardev=omarchy-camera-bridge,name=dev.tryomarchy.camera'
  -chardev "socket,id=omarchy-battery-bridge,path=$battery_bridge_socket,server=on,wait=off"
  -device 'virtserialport,bus=omarchy-serial.0,nr=7,chardev=omarchy-battery-bridge,name=dev.tryomarchy.battery'
)

if [[ -f $resources_dir/integrations/manifest.json ]]; then
  integration_share_option=${resources_dir//,/,,}/integrations
  qemu_args+=(
    -fsdev "local,id=omarchy-updates,path=$integration_share_option,security_model=none,readonly=on"
    -device 'virtio-9p-pci,fsdev=omarchy-updates,mount_tag=tryomarchy-updates,romfile='
    -chardev "socket,id=omarchy-integrations,path=$integration_bridge_socket,server=on,wait=off"
    -device 'virtserialport,bus=omarchy-serial.0,nr=5,chardev=omarchy-integrations,name=dev.tryomarchy.integrations'
  )
fi

if [[ -n $shared_folder ]]; then
  # security_model=none performs every host operation as this Mac user and
  # ignores guest chown requests, so the Mac keeps real modes and ownership.
  # The patched local driver reports this user's files as the Omarchy owner
  # account so the guest kernel grants matching read/write access.
  qemu_args+=(
    -fsdev "local,id=omarchy-share,path=$shared_folder,security_model=none,multidevs=remap,guest_owner_uid=$shared_folder_guest_owner_uid,guest_owner_gid=$shared_folder_guest_owner_gid"
    -device "virtio-9p-pci,fsdev=omarchy-share,mount_tag=$shared_folder_mount_tag,romfile="
  )
fi

# UEFI has no virtio keyboard driver, so GRUB's menu reads a USB keyboard.
# QEMU sends each key to one keyboard; Linux drives both.
qemu_args+=(
  -device 'qemu-xhci,id=roguix-usb'
  -device 'usb-kbd,bus=roguix-usb.0'
)

# SDL2 has one legacy process-wide override that would collapse input and
# output onto the same named device. The patched QEMU backend uses the two
# direction-specific Omarchy variables instead; unset means live System Default.
unset SDL_AUDIO_DEVICE_NAME
export OMARCHY_SDL_AUDIO_CONTROL_DIRECTORY="$audio_route_dir"

if [[ $QEMU_SELECTED_STORAGE_MODE == persistent ]]; then
  qemu_args+=(
    -add-fd "$QEMU_PERSISTENT_STORAGE_QEMU_ADD_FD"
  )
fi

if [[ ${OMARCHY_QEMU_GPU_DRY_RUN:-0} == 1 ]]; then
  printf '[qemu-gpu] dry-run command:' >&2
  printf ' %q' "$qemu_bin" "${qemu_args[@]}" >&2
  printf '\n[qemu-gpu] audio bridge command: %q --bridge-native-audio QEMU_PID %q %q' \
    "$native_bridge" "$audio_bridge_socket" "$audio_route_dir" >&2
  printf '\n[qemu-gpu] clipboard bridge command: %q --bridge-native-clipboard QEMU_PID %q' \
    "$native_bridge" "$clipboard_bridge_socket" >&2
  printf '\n[qemu-gpu] authentication bridge command: %q --bridge-native-authentication QEMU_PID %q' \
    "$native_bridge" "$authentication_bridge_socket" >&2
  printf '\n[qemu-gpu] camera bridge command: %q --bridge-native-camera QEMU_PID %q' \
    "$native_bridge" "$camera_bridge_socket" >&2
  printf '\n[qemu-gpu] battery bridge command: %q --bridge-native-battery QEMU_PID %q' \
    "$native_bridge" "$battery_bridge_socket" >&2
  if [[ -n $shared_folder ]]; then
    printf '\n[qemu-gpu] shared folder: %q' "$shared_folder" >&2
  else
    printf '\n[qemu-gpu] shared folder: disabled' >&2
  fi
  printf '\n[qemu-gpu] port forwarding: %s' "$port_forwarding_summary" >&2
  printf '\n' >&2
  exit 0
fi
[[ ${OMARCHY_QEMU_GPU_DRY_RUN:-0} == 0 ]] || {
  fail "OMARCHY_QEMU_GPU_DRY_RUN must be 0 or 1"
}

if [[ $QEMU_SELECTED_STORAGE_MODE == persistent ]]; then
  echo "[qemu-gpu] Starting the persistent ARM64 VirGL guest with $vcpu_count vCPUs and $memory_display RAM." >&2
  echo "[qemu-gpu] User data: $QEMU_PERSISTENT_STORAGE_DIRECTORY" >&2
else
  echo "[qemu-gpu] Starting a disposable ARM64 VirGL guest with $vcpu_count vCPUs and $memory_display RAM." >&2
fi
if [[ -n $shared_folder ]]; then
  echo "[qemu-gpu] Shared folder: $shared_folder (guest ~/$shared_folder_name)" >&2
fi
echo "[qemu-gpu] Port forwarding: $port_forwarding_summary" >&2
"$qemu_bin" "${qemu_args[@]}" &
qemu_pid=$!
printf '%s\n' "$qemu_pid" >"$work_dir/.qemu.pid"
chmod 600 "$work_dir/.qemu.pid"

for ((attempt = 0; attempt < 100; attempt++)); do
  if [[ -S $qmp_socket && -S $audio_bridge_socket && -S $authentication_bridge_socket && -S $camera_bridge_socket && -S $battery_bridge_socket && -S $clipboard_bridge_socket && -S $settings_bridge_socket ]]; then
    break
  fi
  kill -0 "$qemu_pid" 2>/dev/null || fail "QEMU exited before creating its private QMP socket"
  sleep 0.05
done
[[ -S $qmp_socket ]] || fail "QEMU did not create its private QMP socket"
[[ -S $audio_bridge_socket ]] || fail "QEMU did not create its private audio bridge socket"
[[ -S $authentication_bridge_socket ]] || fail "QEMU did not create its private authentication bridge socket"
[[ -S $camera_bridge_socket ]] || fail "QEMU did not create its private camera bridge socket"
[[ -S $battery_bridge_socket ]] || fail "QEMU did not create its private battery bridge socket"
[[ -S $clipboard_bridge_socket ]] || fail "QEMU did not create its private clipboard bridge socket"
[[ -S $settings_bridge_socket ]] || fail "QEMU did not create its private settings bridge socket"
# The socket file appears before QEMU's main loop accepts connections, and the
# helper tears the VM down if the monitor behind this line does not answer.
# Use the bundled helper so release launches do not depend on host Python.
# Wait on a child so Bash can service cancellation signals during slow init.
"$native_bridge" --wait-for-qmp "$qemu_pid" "$qmp_socket" 9>&- &
monitor_ready_pid=$!
if ! wait "$monitor_ready_pid"; then
  monitor_ready_pid=""
  fail "QEMU's QMP monitor did not become ready"
fi
monitor_ready_pid=""
echo "[qemu-gpu] Ready. QMP: $qmp_socket" >&2

# FD 9 deliberately remains open only in QEMU. Letting the sibling audio
# bridge inherit it could keep a persistent workspace locked after QEMU exits.
"$native_bridge" --bridge-native-audio \
  "$qemu_pid" "$audio_bridge_socket" "$audio_route_dir" 9>&- &
audio_bridge_pid=$!

start_clipboard_bridge() {
  "$native_bridge" --bridge-native-clipboard \
    "$qemu_pid" "$clipboard_bridge_socket" 9>&- &
  clipboard_bridge_pid=$!
}
start_clipboard_bridge
clipboard_bridge_restarts=0

start_authentication_bridge() {
  "$native_bridge" --bridge-native-authentication \
    "$qemu_pid" "$authentication_bridge_socket" 9>&- &
  authentication_bridge_pid=$!
}
start_authentication_bridge
authentication_bridge_restarts=0

if [[ $QEMU_NETWORK_MODE == bridged ]]; then
  "$native_bridge" --bridge-network-link "$qemu_pid" "$qmp_socket" \
    "$QEMU_NETWORK_DIRECTORY/link-state" 9>&- &
  network_link_bridge_pid=$!
fi

start_camera_bridge() {
  "$native_bridge" --bridge-native-camera \
    "$qemu_pid" "$camera_bridge_socket" 9>&- &
  camera_bridge_pid=$!
}
start_camera_bridge
camera_bridge_restarts=0

start_battery_bridge() {
  "$native_bridge" --bridge-native-battery \
    "$qemu_pid" "$battery_bridge_socket" 9>&- &
  battery_bridge_pid=$!
}
start_battery_bridge
battery_bridge_restarts=0

if [[ -f $resources_dir/integrations/manifest.json ]]; then
  integration_cache="$work_dir/integration-status.json"
  if [[ $QEMU_SELECTED_STORAGE_MODE == persistent ]]; then
    integration_disk_inode=$(stat -f %i "$working_disk")
    integration_cache="${QEMU_PERSISTENT_STORAGE_DISKS_ROOT%/disks}/integration-status-$integration_disk_inode.json"
  fi
  "$native_bridge" --bridge-integrations "$qemu_pid" "$integration_bridge_socket" \
    "$integration_cache" 9>&- &
  integration_bridge_pid=$!
fi

# The loop below runs for the whole session. One ps call per poll reads every
# supervised process's state, and the poll sleeps 0.5 s: a ps per process ten
# times a second was a measurable share of the Mac's energy use. States come
# from ps rather than kill -0 because an exited child stays a zombie (Z) until
# it is waited for.
supervised_states=''
refresh_supervised_states() {
  local pids=$qemu_pid
  local pid
  for pid in "$audio_bridge_pid" "$clipboard_bridge_pid" \
    "$authentication_bridge_pid" "$camera_bridge_pid" \
    "$battery_bridge_pid" "$integration_bridge_pid"; do
    [[ $pid =~ ^[0-9]+$ ]] && pids+=",$pid"
  done
  supervised_states=$(ps -o pid=,state= -p "$pids" 2>/dev/null || true)
}
# supervised_state PID VARIABLE: set VARIABLE to PID's state from the last
# refresh, or to empty when it is gone. No subshell, so no extra process.
supervised_state() {
  local wanted=$1
  local pid state
  printf -v "$2" '%s' ''
  while read -r pid state; do
    if [[ $pid == "$wanted" ]]; then
      printf -v "$2" '%s' "$state"
      return 0
    fi
  done <<<"$supervised_states"
}

# Bash 3.2 has no `wait -n`. The native-audio bridge is required for the guest
# transport, so watch it alongside QEMU and fail if it exits unexpectedly.
qemu_is_running() {
  local state
  state=$(ps -p "$qemu_pid" -o state= 2>/dev/null || true)
  [[ -n $state && $state != *Z* ]]
}

while true; do
  refresh_supervised_states
  supervised_state "$qemu_pid" qemu_state
  [[ -n $qemu_state && $qemu_state != *Z* ]] || break

  if [[ $QEMU_NETWORK_MODE == bridged && -f $QEMU_NETWORK_DIRECTORY/failed ]]; then
    cat "$QEMU_NETWORK_DIRECTORY/log" >&2
    fail 'The network helper stopped while Omarchy was running.'
  fi
  if [[ $QEMU_NETWORK_MODE == bridged && ( -f $QEMU_NETWORK_DIRECTORY/done || ! -d $QEMU_NETWORK_DIRECTORY ) ]]; then
    fail 'The networking session ended while Omarchy was running.'
  fi
  supervised_state "$audio_bridge_pid" audio_bridge_state
  if [[ -z $audio_bridge_state || $audio_bridge_state == *Z* ]]; then
    if wait "$audio_bridge_pid"; then
      audio_bridge_status=0
    else
      audio_bridge_status=$?
    fi
    audio_bridge_pid=""
    # QEMU closes its channels before its process finishes exiting. Give that
    # teardown a short grace period, then use QEMU's real exit status below.
    # A bridge failure while QEMU stays alive must still fail the launch.
    for ((attempt = 0; attempt < 40; attempt++)); do
      qemu_is_running || break
      sleep 0.05
    done
    qemu_is_running || break
    fail "native audio bridge exited while QEMU was running (status $audio_bridge_status)"
  fi

  # Clipboard sharing is a convenience, not a transport the guest depends on.
  # Restart it a few times rather than stopping the whole virtual machine.
  if [[ $clipboard_bridge_pid =~ ^[0-9]+$ ]]; then
    supervised_state "$clipboard_bridge_pid" clipboard_bridge_state
    if [[ -z $clipboard_bridge_state || $clipboard_bridge_state == *Z* ]]; then
      if wait "$clipboard_bridge_pid"; then
        clipboard_bridge_status=0
      else
        clipboard_bridge_status=$?
      fi
      clipboard_bridge_pid=""
      if (( clipboard_bridge_restarts < 5 )); then
        clipboard_bridge_restarts=$((clipboard_bridge_restarts + 1))
        echo "[qemu-gpu] clipboard bridge exited (status $clipboard_bridge_status); restarting ($clipboard_bridge_restarts/5)" >&2
        sleep 1
        qemu_is_running || break
        start_clipboard_bridge
      else
        echo "[qemu-gpu] clipboard sharing is unavailable for the rest of this session" >&2
      fi
    fi
  fi
  # Touch ID sudo remains optional to VM availability: signed-response failure
  # falls back to the guest password. Reconnect a transiently failed helper.
  if [[ $authentication_bridge_pid =~ ^[0-9]+$ ]]; then
    supervised_state "$authentication_bridge_pid" authentication_bridge_state
    if [[ -z $authentication_bridge_state || $authentication_bridge_state == *Z* ]]; then
      if wait "$authentication_bridge_pid"; then
        authentication_bridge_status=0
      else
        authentication_bridge_status=$?
      fi
      authentication_bridge_pid=""
      if (( authentication_bridge_restarts < 5 )); then
        authentication_bridge_restarts=$((authentication_bridge_restarts + 1))
        echo "[qemu-gpu] authentication bridge exited (status $authentication_bridge_status); restarting ($authentication_bridge_restarts/5)" >&2
        sleep 1
        start_authentication_bridge
      else
        echo "[qemu-gpu] Touch ID sudo is unavailable for the rest of this session; password authentication remains available" >&2
      fi
    fi
  fi
  # Camera sharing is optional. A failed capture backend must not stop the VM;
  # reconnect it so a transient device change can recover in this session.
  if [[ $camera_bridge_pid =~ ^[0-9]+$ ]]; then
    supervised_state "$camera_bridge_pid" camera_bridge_state
    if [[ -z $camera_bridge_state || $camera_bridge_state == *Z* ]]; then
      if wait "$camera_bridge_pid"; then
        camera_bridge_status=0
      else
        camera_bridge_status=$?
      fi
      camera_bridge_pid=""
      if (( camera_bridge_restarts < 5 )); then
        camera_bridge_restarts=$((camera_bridge_restarts + 1))
        echo "[qemu-gpu] camera bridge exited (status $camera_bridge_status); restarting ($camera_bridge_restarts/5)" >&2
        sleep 1
        qemu_is_running || break
        start_camera_bridge
      else
        echo "[qemu-gpu] camera sharing is unavailable for the rest of this session" >&2
      fi
    fi
  fi
  # Battery mirroring is optional. A failed IOKit backend must not stop the
  # VM; reconnect it so a transient failure can recover in this session.
  if [[ $battery_bridge_pid =~ ^[0-9]+$ ]]; then
    supervised_state "$battery_bridge_pid" battery_bridge_state
    if [[ -z $battery_bridge_state || $battery_bridge_state == *Z* ]]; then
      if wait "$battery_bridge_pid"; then
        battery_bridge_status=0
      else
        battery_bridge_status=$?
      fi
      battery_bridge_pid=""
      if (( battery_bridge_restarts < 5 )); then
        battery_bridge_restarts=$((battery_bridge_restarts + 1))
        echo "[qemu-gpu] battery bridge exited (status $battery_bridge_status); restarting ($battery_bridge_restarts/5)" >&2
        sleep 1
        start_battery_bridge
      else
        echo "[qemu-gpu] battery mirroring is unavailable for the rest of this session" >&2
      fi
    fi
  fi
  sleep 0.5
done

if wait "$qemu_pid"; then
  qemu_status=0
else
  qemu_status=$?
fi
qemu_pid=""

for ((attempt = 0; attempt < 40; attempt++)); do
  audio_bridge_state=$(ps -p "$audio_bridge_pid" -o state= 2>/dev/null || true)
  [[ -n $audio_bridge_state && $audio_bridge_state != *Z* ]] || break
  sleep 0.05
done
audio_bridge_state=$(ps -p "$audio_bridge_pid" -o state= 2>/dev/null || true)
if [[ -n $audio_bridge_state && $audio_bridge_state != *Z* ]]; then
  terminate_child "$audio_bridge_pid" 20
else
  wait "$audio_bridge_pid" 2>/dev/null || true
fi
audio_bridge_pid=""
if [[ $authentication_bridge_pid =~ ^[0-9]+$ ]]; then
  terminate_child "$authentication_bridge_pid" 20
fi
authentication_bridge_pid=""
if [[ $clipboard_bridge_pid =~ ^[0-9]+$ ]]; then
  terminate_child "$clipboard_bridge_pid" 20
fi
clipboard_bridge_pid=""
if [[ $camera_bridge_pid =~ ^[0-9]+$ ]]; then
  terminate_child "$camera_bridge_pid" 20
fi
camera_bridge_pid=""
if [[ $battery_bridge_pid =~ ^[0-9]+$ ]]; then
  terminate_child "$battery_bridge_pid" 20
fi
battery_bridge_pid=""
exit "$qemu_status"
