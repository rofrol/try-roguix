#!/bin/bash

set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd -P)
macos_dir=$(cd "$test_dir/.." && pwd -P)

fail() {
  printf 'run-qemu-ssh-contract.test: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  [[ $1 == *"$2"* ]] || fail "expected output to contain [$2], got [$1]"
}

assert_not_contains() {
  [[ $1 != *"$2"* ]] || fail "expected output not to contain [$2], got [$1]"
}

assert_line_pair() {
  local file=$1
  local first=$2
  local second=$3
  awk -v first="$first" -v second="$second" \
    'previous == first && $0 == second { found = 1 } { previous = $0 } END { exit !found }' \
    "$file" || fail "expected adjacent lines [$first] and [$second] in $file"
}

assert_keyboard_lockstep() {
  local log=$1
  local geometry=$2
  local other
  [[ $(grep -o "tryomarchy.keyboard=$geometry" "$log" | wc -l | tr -d ' ') == 1 ]] || \
    fail "expected exactly one tryomarchy.keyboard=$geometry token in $log"
  [[ $(grep -c "^TRYOMARCHY_KEYBOARD=$geometry$" "$log") == 1 ]] || \
    fail "Cocoa env must match cmdline token $geometry in $log"
  for other in ansi iso jis; do
    if [[ $other != "$geometry" ]]; then
      assert_not_contains "$(<"$log")" "tryomarchy.keyboard=$other"
      assert_not_contains "$(<"$log")" "TRYOMARCHY_KEYBOARD=$other"
    fi
  done
}

test_root=$(mktemp -d '/private/tmp/omarchy-qemu-ssh-contract.XXXXXX')
case "$test_root" in
  /private/tmp/omarchy-qemu-ssh-contract.??????) ;;
  *) fail "unexpected test root: $test_root" ;;
esac
stale_fixture=''
trap '/bin/rm -rf "$test_root"; [[ -z "$stale_fixture" ]] || /bin/rm -rf "$stale_fixture"' EXIT HUP INT TERM

app="$test_root/Try Roguix.app"
contents="$app/Contents"
resources="$contents/Resources"
shim_dir="$test_root/bin"
mkdir -p \
  "$contents/MacOS" \
  "$resources/guest" \
  "$resources/runtime/bin" \
  "$resources/scripts" \
  "$shim_dir"

# The copied launcher must never reap another app's live run directories.
# Keep the unique prefix directly in /private/tmp for short Unix socket paths.
sed "s|/private/tmp/omarchy-qemu-gpu\\.|/private/tmp/${test_root##*/}-run.|g" \
  "$macos_dir/run-qemu-gpu.sh" >"$resources/scripts/run-qemu-gpu.sh"
if grep -Fq '/private/tmp/omarchy-qemu-gpu.' "$resources/scripts/run-qemu-gpu.sh"; then
  fail "test launcher still refers to production run directories"
fi
/bin/cp "$macos_dir/qemu-port-forwarding.sh" "$resources/scripts/qemu-port-forwarding.sh"
/bin/cp "$macos_dir/qemu-networking.sh" "$resources/scripts/qemu-networking.sh"
chmod 755 "$resources/scripts/run-qemu-gpu.sh"
chmod 644 "$resources/scripts/qemu-port-forwarding.sh"

mkdir -p "$resources/guest-settings" "$resources/integrations"
printf '{}\n' >"$resources/integrations/manifest.json"
cp "$macos_dir/guest-settings.service" "$resources/guest-settings/guest-settings.service"
cp "$macos_dir/../guest/scripts/install-settings-integration.py" "$resources/guest-settings/install.py"

cat >"$contents/MacOS/omarchy-vm-helper" <<'SH'
#!/bin/bash
set -euo pipefail
if [[ ${1:-} == --wait-for-qmp ]]; then
  if [[ -n ${FAKE_QMP_READY_WAIT:-} ]]; then
    printf '%s %s %s\n' "$$" "$PPID" "$2" >"$FAKE_QMP_READY_WAIT"
    while true; do sleep 0.1; done
  fi
  if [[ -n ${REAL_QMP_HELPER:-} ]]; then
    exec "$REAL_QMP_HELPER" "$@"
  fi
  exit "${FAKE_QMP_READY_STATUS:-0}"
fi
if [[ ${1:-} == --host-keyboard-geometry ]]; then
  if [[ -n ${FAKE_HOST_KEYBOARD_FAIL:-} ]]; then
    printf 'cannot detect host keyboard geometry\n' >&2
    exit 1
  fi
  printf '%s\n' "${FAKE_HOST_KEYBOARD:-iso}"
  exit 0
fi
if [[ ${1:-} == --bridge-native-audio && ${FAKE_SHUTDOWN_RACE:-0} == 1 ]]; then
  printf '%s\n' "$$" >"$FAKE_QEMU_LOG.audio.pid"
fi
if [[ ${1:-} == --bridge-native-audio && ${FAKE_AUDIO_EARLY_EXIT:-0} == 1 ]]; then
  sleep 0.05
  exit 0
elif [[ ${1:-} == --bridge-native-audio && -n ${FAKE_AUDIO_BRIDGE_LIFETIME:-} ]]; then
  sleep "$FAKE_AUDIO_BRIDGE_LIFETIME"
  exit "${FAKE_AUDIO_BRIDGE_STATUS:-0}"
fi
if [[ ${1:-} == --bridge-native-audio \
   || ${1:-} == --bridge-native-authentication \
   || ${1:-} == --bridge-native-clipboard \
   || ${1:-} == --bridge-native-camera \
   || ${1:-} == --bridge-native-battery ]]; then
  if [[ $1 == --bridge-native-audio && ${FAKE_AUDIO_EXIT_EARLY:-0} == 1 ]]; then
    exit 0
  fi
  while kill -0 "$2" 2>/dev/null; do
    sleep 0.02
  done
fi
exit 0
SH
chmod 755 "$contents/MacOS/omarchy-vm-helper"

cat >"$resources/runtime/bin/Try Roguix" <<'SH'
#!/bin/bash
# Identity markers validated by the production launcher:
# TryRoguix.icns
# OMARCHY_SDL_AUDIO_CONTROL_DIRECTORY
# OMARCHY_SDL_INPUT_DEVICE_NAME
# OMARCHY_SDL_OUTPUT_DEVICE_NAME
# guest_owner_uid guest_owner_gid
# hv_vm_config_set_el2_enabled hv_gic_create
# HVF free-page backing replacement failed
case " $* " in
  *' -accel help '*) printf '%s\n' hvf ;;
  *' -machine help '*) printf '%s\n' 'virt                 ARM Virtual Machine' ;;
  *' -cpu help '*) printf '%s\n' '  host' ;;
  *' -display help '*) printf '%s\n' cocoa ;;
  *' -device help '*)
    for device in \
      hda-micro intel-hda virtconsole virtserialport virtio-balloon-pci \
      virtio-9p-pci virtio-blk-pci virtio-gpu-gl-pci virtio-keyboard-pci \
      virtio-net-pci virtio-rng-pci virtio-serial-pci virtio-tablet-pci virtio-pinch-pci \
      qemu-xhci usb-kbd; do
      printf 'name "%s"\n' "$device"
    done
    ;;
  *' -help '*)
    printf '%s\n' \
      '-add-fd fd=fd,set=set[,opaque=opaque]' \
      '-action reboot=reset|shutdown' \
      'full-grab=on|off' \
      'immersive=on|off'
    if [[ ${FAKE_QEMU_MISSING_SHUTDOWN:-0} != 1 ]]; then
      printf '%s\n' '-action shutdown=poweroff|pause'
    fi
    if [[ ${FAKE_QEMU_LARGE_HELP:-0} == 1 ]]; then
      printf '%131072s\n' ''
    fi
    ;;
  *' -machine virt -netdev help '*) printf '%s\n' user stream ;;
  *' -machine virt -audiodev help '*) printf '%s\n' sdl ;;
  *' -device virtio-gpu-gl-pci,help '*) printf '%s\n' 'romfile=<str>' ;;
  *' -machine virt,gic-version=3,virtualization=on '*' -qmp stdio '*)
    printf 'probe\n' >>"$FAKE_QEMU_NESTED_LOG"
    exit "${FAKE_QEMU_NESTED_STATUS:-0}"
    ;;
  *)
    exec /usr/bin/python3 - "$@" <<'PY'
import json
import os
from pathlib import Path
import signal
import socket
import sys
import threading
import time

arguments = sys.argv[1:]
geometry = os.environ.get("TRYOMARCHY_KEYBOARD", "")
Path(os.environ["FAKE_QEMU_LOG"]).write_text(
    "\n".join(arguments) + f"\nTRYOMARCHY_KEYBOARD={geometry}\n"
)
Path(os.environ["FAKE_QEMU_LOG"] + ".pid").write_text(str(os.getpid()))
qmp_paths = {
    arguments[index + 1][5:].split(",", 1)[0]
    for index, argument in enumerate(arguments[:-1])
    if argument == "-qmp" and arguments[index + 1].startswith("unix:")
}
socket_paths = []
for argument in arguments:
    if argument.startswith("unix:"):
        socket_paths.append(argument[5:].split(",", 1)[0])
    elif argument.startswith("socket,"):
        for field in argument.split(","):
            if field.startswith("path="):
                socket_paths.append(field[5:])

servers = []
qmp_ready = threading.Event()
if os.environ.get("FAKE_QEMU_SKIP_SOCKETS") != "1":
    for path in socket_paths:
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        server = socket.socket(socket.AF_UNIX)
        server.bind(path)
        server.listen(1)
        servers.append(server)
        # Like QEMU, answer the QMP monitor with a greeting; the launcher
        # waits for that before declaring the VM ready.
        if path in qmp_paths:
            def greet(server=server):
                while True:
                    try:
                        client, _ = server.accept()
                    except OSError:
                        return
                    try:
                        client.settimeout(1)
                        client.sendall(b'{"QMP": {"version": {}, "capabilities": []}}\r\n')
                        with client.makefile("rb") as stream:
                            request = json.loads(stream.readline())
                        assert request["execute"] == "qmp_capabilities"
                        client.sendall(json.dumps({"return": {}, "id": request["id"]}).encode() + b"\r\n")
                        qmp_ready.set()
                    except (OSError, ValueError):
                        pass
                    client.close()
            threading.Thread(target=greet, daemon=True).start()

if os.environ.get("FAKE_QEMU_WAIT_FOR_QMP") == "1" and not qmp_ready.wait(10):
    raise SystemExit("fake QEMU timed out waiting for the readiness handshake")

if os.environ.get("FAKE_SHUTDOWN_RACE") == "1":
    # Stay alive until ps has captured a live snapshot and the audio bridge
    # has started. The deadline bounds a broken fixture, not a successful run.
    deadline = time.monotonic() + 10
    while not Path(os.environ[log_variable] + ".raced").exists():
        if time.monotonic() >= deadline:
            Path(os.environ[log_variable] + ".timed-out").touch()
            raise SystemExit("fake QEMU timed out waiting for the shutdown race")
        time.sleep(0.01)
elif os.environ.get("FAKE_QEMU_WAIT_FOR_TERMINATION") == "1":
    # Failure scenarios need QEMU alive until launcher cleanup, regardless of
    # host speed. The alarm only bounds a broken launcher/test, not success.
    def timed_out(signum, frame):
        Path(os.environ[log_variable] + ".timed-out").touch()
        raise SystemExit("fake QEMU timed out waiting for launcher cleanup")

    signal.signal(signal.SIGALRM, timed_out)
    signal.alarm(60)
    signal.pause()
else:
    time.sleep(float(os.environ.get("FAKE_QEMU_LIFETIME", "0.20")))
for server in servers:
    server.close()
raise SystemExit(int(os.environ.get("FAKE_QEMU_STATUS", "0")))
PY
    ;;
esac
SH
chmod 755 "$resources/runtime/bin/Try Roguix"

cat >"$resources/scripts/qemu-persistent-storage.sh" <<'SH'
#!/bin/bash
QEMU_PERSISTENT_STORAGE_INCOMPATIBLE_STATUS=78
QEMU_PERSISTENT_STORAGE_MISSING_STATUS=79
QEMU_PERSISTENT_STORAGE_QEMU_ADD_FD='fd=9,set=77,opaque=omarchy-persistent-lock'
QEMU_SELECTED_DISK=''
QEMU_SELECTED_STORAGE_MODE=''
QEMU_PERSISTENT_STORAGE_DIRECTORY=''
QEMU_PERSISTENT_STORAGE_ROOT=''
QEMU_PERSISTENT_STORAGE_IDENTITY=''
_qps_owner() { /usr/bin/stat -f '%u' "$1"; }
_qps_permissions() { /usr/bin/stat -f '%Lp' "$1"; }
_qps_lstat_kind() { /usr/bin/stat -f '%HT' "$1"; }
_qps_size() { /usr/bin/stat -f '%z' "$1"; }
qemu_persistent_storage_release_lock() { :; }
qemu_persistent_storage_materialize_source() {
  printf 'materialize\n' >>"$FAKE_STORAGE_LOG"
  return 1
}
qemu_persistent_storage_select_existing() {
  printf 'select-existing\n' >>"$FAKE_STORAGE_LOG"
  QEMU_SELECTED_DISK="$FAKE_PERSISTENT_ROOT/disk.raw"
  if [[ ! -f $QEMU_SELECTED_DISK ]]; then
    QEMU_SELECTED_DISK=''
    return "$QEMU_PERSISTENT_STORAGE_MISSING_STATUS"
  fi
  printf 'reuse\n' >>"$FAKE_STORAGE_LOG"
  QEMU_SELECTED_STORAGE_MODE=persistent
  QEMU_PERSISTENT_STORAGE_DIRECTORY=$FAKE_PERSISTENT_ROOT
  QEMU_PERSISTENT_STORAGE_ROOT=$FAKE_PERSISTENT_ROOT
  QEMU_PERSISTENT_STORAGE_IDENTITY=${FAKE_SAVED_IDENTITY:-saved-vm}
}
qemu_persistent_storage_select() {
  printf 'select %s\n' "$1" >>"$FAKE_STORAGE_LOG"
  if [[ $1 == ephemeral ]]; then
    mkdir -p "$6"
    QEMU_SELECTED_DISK="$6/disk.raw"
    /bin/cp "$3" "$QEMU_SELECTED_DISK"
    chmod 600 "$QEMU_SELECTED_DISK"
    QEMU_SELECTED_STORAGE_MODE=ephemeral
    QEMU_PERSISTENT_STORAGE_DIRECTORY=''
    QEMU_PERSISTENT_STORAGE_ROOT=''
    QEMU_PERSISTENT_STORAGE_IDENTITY=''
    return 0
  fi
  mkdir -p "$FAKE_PERSISTENT_ROOT"
  QEMU_SELECTED_DISK="$FAKE_PERSISTENT_ROOT/disk.raw"
  if [[ $1 != reset && -f $QEMU_SELECTED_DISK ]]; then
    printf 'reuse\n' >>"$FAKE_STORAGE_LOG"
  else
    printf 'factory\n' >"$QEMU_SELECTED_DISK"
    printf 'create\n' >>"$FAKE_STORAGE_LOG"
  fi
  chmod 600 "$QEMU_SELECTED_DISK"
  QEMU_SELECTED_STORAGE_MODE=persistent
  QEMU_PERSISTENT_STORAGE_DIRECTORY=$FAKE_PERSISTENT_ROOT
  QEMU_PERSISTENT_STORAGE_ROOT=$FAKE_PERSISTENT_ROOT
  QEMU_PERSISTENT_STORAGE_IDENTITY=${FAKE_SAVED_IDENTITY:-saved-vm}
}
SH
chmod 644 "$resources/scripts/qemu-persistent-storage.sh"

cat >"$shim_dir/codesign" <<'SH'
#!/bin/bash
for argument in "$@"; do
  if [[ $argument == -d ]]; then
    printf '%s\n' '<key>com.apple.security.hypervisor</key>' >&2
  fi
done
exit 0
SH
cat >"$shim_dir/file" <<'SH'
#!/bin/bash
printf '%s: Mach-O 64-bit executable arm64\n' "$1"
SH
cat >"$shim_dir/sw_vers" <<'SH'
#!/bin/bash
[[ $* == -productVersion ]] || exit 1
printf '%s\n' "${FAKE_MACOS_VERSION-26.0}"
exit "${FAKE_MACOS_VERSION_STATUS:-0}"
SH
cat >"$shim_dir/sysctl" <<'SH'
#!/bin/bash
if [[ $# == 2 && $1 == -n && ($2 == hw.logicalcpu || $2 == hw.ncpu) ]]; then
  printf '%s\n' "${FAKE_HOST_CPUS:-8}"
  exit 0
fi
if [[ $# == 2 && $1 == -n && $2 == hw.memsize ]]; then
  printf '%s\n' "${FAKE_HOST_MEMORY_BYTES:-51539607552}"
  exit 0
fi
exec /usr/sbin/sysctl "$@"
SH
cat >"$shim_dir/ps" <<'SH'
#!/bin/bash
[[ ${FAKE_PROCESS_INSPECTION_UNAVAILABLE:-0} != 1 ]] || exit 77
if [[ ${FAKE_PS_DELAY:-0} != 0 && $* == *' -o state=' ]]; then
  sleep "$FAKE_PS_DELAY"
fi
if [[ ${FAKE_LARGE_PROCESS_LIST:-0} == 1 && "$*" == "-axo pid=,command=" ]]; then
  printf '999999 /bin/bash run-qemu-gpu.sh\n'
  /usr/bin/awk 'BEGIN { for (i=0; i<10000; i++) print 800000+i, "unrelated process with enough output to fill a pipe buffer" }'
fi
if [[ ${FAKE_SHUTDOWN_RACE:-0} == 1 && -f ${FAKE_QEMU_LOG:-}.pid \
   && $* == "-p $(cat "$FAKE_QEMU_LOG.pid") -o state=" \
   && ! -e $FAKE_QEMU_LOG.raced ]]; then
  state=$(/bin/ps "$@" 2>/dev/null) || exit $?
  [[ -n $state && $state != *Z* ]] || exit 1
  for ((attempt=0; attempt<500; attempt++)); do
    [[ -s $FAKE_QEMU_LOG.audio.pid ]] && break
    sleep 0.02
  done
  if [[ ! -s $FAKE_QEMU_LOG.audio.pid ]]; then
    touch "$FAKE_QEMU_LOG.timed-out"
    exit 1
  fi
  touch "$FAKE_QEMU_LOG.raced"
  # Return a stale live snapshot only after QEMU and its bridges have exited.
  for pid_file in "$FAKE_QEMU_LOG.pid" "$FAKE_QEMU_LOG.audio.pid"; do
    target_pid=$(cat "$pid_file")
    for ((attempt=0; attempt<500; attempt++)); do
      current_state=$(/bin/ps -p "$target_pid" -o state= 2>/dev/null || true)
      [[ -n $current_state && $current_state != *Z* ]] || break
      sleep 0.02
    done
    if [[ -n $current_state && $current_state != *Z* ]]; then
      touch "$FAKE_QEMU_LOG.timed-out"
      exit 1
    fi
  done
  printf '%s\n' "$state"
  exit 0
fi
exec /bin/ps "$@"
SH
chmod 755 "$shim_dir"/*

guest="$resources/guest"
firmware="$resources/runtime/share/qemu/edk2-aarch64-code.fd"
mkdir -p "$resources/runtime/share/qemu"
printf 'firmware\n' >"$firmware"
printf 'factory\n' >"$guest/disk.raw"
/usr/bin/plutil -create xml1 "$guest/launch.plist"
/usr/bin/plutil -insert bundleIdentity -string "$(printf 'a%.0s' {1..64})" "$guest/launch.plist"
/usr/bin/plutil -insert sourceDiskSHA256 -string "$(printf 'b%.0s' {1..64})" "$guest/launch.plist"
/usr/bin/plutil -insert sourceDiskBytes -integer 8 "$guest/launch.plist"
/usr/bin/plutil -insert compressedDiskBytes -integer 4 "$guest/launch.plist"
/usr/bin/plutil -insert workingDiskBytes -integer 16 "$guest/launch.plist"
/usr/bin/plutil -insert bootABI -string uefi-gpt-v1 "$guest/launch.plist"

launcher="$resources/scripts/run-qemu-gpu.sh"
persistent_root="$test_root/persistent"

# The repo-local development path has no launch.plist: the launcher asks the
# bundled guix-artifact.py for the launch record (test_artifact.py covers its
# validation) and only accepts a packaged Roguix guest directory.
development_record="$(printf 'c%.0s' {1..64})	$(printf 'd%.0s' {1..64})	8	4	16"
printf '%s\n' \
  'import sys' \
  'assert sys.argv[1:2] == ["launch-record"]' \
  "print('$development_record')" \
  >"$resources/scripts/guix-artifact.py"
development_guest="$resources/development-guest"
mkdir -p "$development_guest"
development_stderr="$test_root/development-validation.stderr"
if env PATH="$shim_dir:/usr/bin:/bin:/usr/sbin:/sbin" OMARCHY_QEMU_GPU_INSPECT_ONLY=1 \
  "$launcher" "$development_guest" >/dev/null 2>"$development_stderr"; then
  fail 'a directory without guix-manifest.json passed development validation'
fi
assert_contains "$(<"$development_stderr")" 'not a packaged Roguix guest'
printf '{}\n' >"$development_guest/guix-manifest.json"
if ! development_validation=$(env \
  PATH="$shim_dir:/usr/bin:/bin:/usr/sbin:/sbin" \
  OMARCHY_QEMU_GPU_INSPECT_ONLY=1 \
  "$launcher" "$development_guest" 2>"$development_stderr"); then
  /bin/cat "$development_stderr" >&2 || true
  fail 'the development launch record failed validation'
fi
[[ $development_validation == "$development_record" ]] || \
  fail "unexpected development launch record: $development_validation"

run_scenario() {
  local scenario=$1
  local expected_status=$2
  local launcher_argument=$3
  shift 3
  local scenario_dir="$test_root/$scenario"
  local actual_status=0
  mkdir -p "$scenario_dir"
  : >"$scenario_dir/storage.log"
  if env \
    -u OMARCHY_QEMU_GPU_CPUS -u OMARCHY_QEMU_GPU_MEMORY_MIB \
    PATH="$shim_dir:/usr/bin:/bin:/usr/sbin:/sbin" \
    FAKE_STORAGE_LOG="$scenario_dir/storage.log" \
    FAKE_PERSISTENT_ROOT="$persistent_root" \
    FAKE_QEMU_LOG="$scenario_dir/qemu.log" \
    FAKE_QEMU_NESTED_LOG="$scenario_dir/nested.log" \
    "$@" \
    "$launcher" ${launcher_argument:+"$launcher_argument"} \
    >"$scenario_dir/stdout" 2>"$scenario_dir/stderr"; then
    actual_status=0
  else
    actual_status=$?
  fi
  [[ ! -e $scenario_dir/qemu.log.timed-out ]] || fail "$scenario timed out waiting for launcher cleanup"
  if [[ $actual_status != "$expected_status" ]]; then
    /bin/cat "$scenario_dir/stderr" >&2 || true
    fail "$scenario expected status $expected_status, got $actual_status"
  fi
}

run_scenario disabled 0 ''
disabled_qemu=$(<"$test_root/disabled/qemu.log")
assert_contains "$disabled_qemu" 'systemd.wants=try-omarchy-settings.service'
assert_contains "$disabled_qemu" "systemd.set_credential_binary=systemd.extra-unit.try-omarchy-settings.service:$(base64 < "$macos_dir/guest-settings.service" | tr -d '\r\n')"
assert_line_pair "$test_root/disabled/qemu.log" -fsdev \
  "local,id=omarchy-settings,path=$resources/guest-settings,security_model=none,readonly=on"
assert_not_contains "$disabled_qemu" 'systemd.unit='
assert_line_pair "$test_root/disabled/qemu.log" -machine \
  'virt,gic-version=3,virtualization=on'
assert_line_pair "$test_root/disabled/qemu.log" -accel 'hvf,kernel-irqchip=on'
assert_not_contains "$disabled_qemu" gic-version=2
assert_line_pair "$test_root/disabled/qemu.log" -netdev 'user,id=omarchy-net'
assert_line_pair "$test_root/disabled/qemu.log" -chardev \
  "stdio,id=omarchy-hvc0,signal=off,logfile=$persistent_root/console.log,logappend=off"
assert_line_pair "$test_root/disabled/qemu.log" -bios "$firmware"
for option in -kernel -initrd -append; do
  ! grep -Fxq -- "$option" "$test_root/disabled/qemu.log" || fail "UEFI launch passed $option"
done
assert_line_pair "$test_root/disabled/qemu.log" -name 'Try Roguix'
assert_line_pair "$test_root/disabled/qemu.log" -smbios 'type=11,value=omarchy.qemu_virgl=1'
# UEFI has no virtio keyboard driver; GRUB's menu reads the USB keyboard.
assert_line_pair "$test_root/disabled/qemu.log" -device 'usb-kbd,bus=roguix-usb.0'
assert_contains "$disabled_qemu" "file=$persistent_root/disk.raw"
assert_not_contains "$disabled_qemu" hostfwd
assert_not_contains "$disabled_qemu" tryomarchy.ssh_access
assert_keyboard_lockstep "$test_root/disabled/qemu.log" iso
assert_contains "$disabled_qemu" \
  'cocoa,gl=es,show-cursor=on,zoom-to-fit=on,full-screen=on,full-grab=on,immersive=on,swap-opt-cmd=off'
assert_contains "$disabled_qemu" \
  'socket,id=omarchy-authentication-bridge,path='
assert_contains "$disabled_qemu" \
  'virtserialport,bus=omarchy-serial.0,nr=3,chardev=omarchy-authentication-bridge,name=dev.tryomarchy.authentication'
assert_contains "$disabled_qemu" \
  'socket,id=omarchy-battery-bridge,path='
assert_contains "$disabled_qemu" \
  'virtserialport,bus=omarchy-serial.0,nr=7,chardev=omarchy-battery-bridge,name=dev.tryomarchy.battery'
assert_contains "$disabled_qemu" \
  'virtserialport,bus=omarchy-serial.0,nr=6,chardev=omarchy-settings-bridge,name=dev.tryomarchy.settings'
assert_contains "$disabled_qemu" \
  'virtserialport,bus=omarchy-serial.0,nr=5,chardev=omarchy-integrations,name=dev.tryomarchy.integrations'
# A duplicate bus/port pair makes real QEMU exit before its monitor is usable.
python3 - "$test_root/disabled/qemu.log" <<'PYPORTS'
import pathlib
import sys

ports = set()
for argument in pathlib.Path(sys.argv[1]).read_text().splitlines():
    if not argument.startswith(("virtserialport,", "virtconsole,")):
        continue
    fields = dict(field.split("=", 1) for field in argument.split(",")[1:])
    port = (fields["bus"], fields["nr"])
    assert port not in ports, f"Duplicate virtual serial port: {port}"
    ports.add(port)
assert len(ports) == 8, f"Expected all eight guest channels, got {ports}"
PYPORTS
assert_contains "$(<"$test_root/disabled/storage.log")" select-existing
assert_contains "$(<"$test_root/disabled/storage.log")" create
assert_line_pair "$test_root/disabled/qemu.log" -smp '8,sockets=1,cores=8,threads=1'
assert_line_pair "$test_root/disabled/qemu.log" -m 8192M

# Valid help larger than a pipe buffer must not fail when a capability matches
# near the start. Missing capabilities must still be rejected before launch.
run_scenario large-help 0 '' FAKE_QEMU_LARGE_HELP=1
run_scenario missing-shutdown 1 '' FAKE_QEMU_LARGE_HELP=1 FAKE_QEMU_MISSING_SHUTDOWN=1
assert_contains "$(<"$test_root/missing-shutdown/stderr")" \
  'staged QEMU cannot apply the required shutdown policy'
[[ ! -e $test_root/missing-shutdown/qemu.log ]] || fail 'missing shutdown policy started QEMU'

# Release launches must work without a usable host interpreter. The fake
# QEMU uses an absolute interpreter path only as test infrastructure.
cat >"$shim_dir/python3" <<'SH'
#!/bin/bash
printf 'unexpected runtime Python invocation\n' >>"$NO_PYTHON_LOG"
exit 127
SH
chmod 755 "$shim_dir/python3"
real_helper="$macos_dir/.build/debug/omarchy-vm-helper"
[[ -x $real_helper ]] || fail 'build the native helper with swift build before running this test'
run_scenario no-python 0 '' "REAL_QMP_HELPER=$real_helper" \
  "NO_PYTHON_LOG=$test_root/python.log" FAKE_QEMU_WAIT_FOR_QMP=1
[[ ! -e $test_root/python.log ]] || fail 'release launcher invoked Python'
assert_contains "$(<"$test_root/no-python/stderr")" '[qemu-gpu] Ready. QMP:'
/bin/rm -f "$shim_dir/python3"

run_scenario monitor-failure 1 '' FAKE_QMP_READY_STATUS=1 FAKE_QEMU_LIFETIME=10
assert_contains "$(<"$test_root/monitor-failure/stderr")" "QEMU's QMP monitor did not become ready"
assert_not_contains "$(<"$test_root/monitor-failure/stderr")" '[qemu-gpu] Ready. QMP:'

# Cancelling a launch while the monitor is initializing must reap both the
# readiness helper and QEMU rather than wait for the 60-second deadline.
run_scenario monitor-cancel 143 '' FAKE_QEMU_LIFETIME=10 \
  "FAKE_QMP_READY_WAIT=$test_root/readiness-pids" &
cancel_scenario_pid=$!
for ((attempt=0; attempt<100; attempt++)); do
  [[ -s $test_root/readiness-pids ]] && break
  sleep 0.05
done
[[ -s $test_root/readiness-pids ]] || fail 'readiness helper did not start for cancellation test'
read -r readiness_pid launcher_pid target_pid <"$test_root/readiness-pids"
kill -TERM "$launcher_pid"
wait "$cancel_scenario_pid" || fail 'cancelling monitor readiness did not stop the launcher'
for stopped_pid in "$readiness_pid" "$target_pid"; do
  if kill -0 "$stopped_pid" 2>/dev/null; then
    fail "cancelling readiness left child $stopped_pid running"
  fi
done
assert_not_contains "$(<"$test_root/monitor-cancel/stderr")" '[qemu-gpu] Ready. QMP:'

# Deliberately exceed the old 0.20-second lifetime before capturing the state.
run_scenario shutdown-race 0 '' FAKE_SHUTDOWN_RACE=1 FAKE_PS_DELAY=0.3
[[ -e $test_root/shutdown-race/qemu.log.raced ]] || fail 'shutdown race was not exercised'
# Slow process checks deliberately exceed the old two-second QEMU lifetime.
run_scenario audio-exits-early 1 '' \
  FAKE_AUDIO_EXIT_EARLY=1 FAKE_QEMU_WAIT_FOR_TERMINATION=1 FAKE_PS_DELAY=0.1
assert_contains "$(<"$test_root/audio-exits-early/stderr")" 'native audio bridge exited while QEMU was running'

run_scenario keyboard-ansi 0 '' FAKE_HOST_KEYBOARD=ansi
assert_keyboard_lockstep "$test_root/keyboard-ansi/qemu.log" ansi
run_scenario keyboard-jis 0 '' FAKE_HOST_KEYBOARD=jis
assert_keyboard_lockstep "$test_root/keyboard-jis/qemu.log" jis
run_scenario keyboard-helper-fail 1 '' FAKE_HOST_KEYBOARD_FAIL=1
assert_contains "$(<"$test_root/keyboard-helper-fail/stderr")" \
  'cannot detect the host Mac keyboard geometry'
[[ ! -e $test_root/keyboard-helper-fail/qemu.log ]] || \
  fail 'failed keyboard probe started QEMU'
run_scenario keyboard-invalid 1 '' FAKE_HOST_KEYBOARD=ISO
assert_contains "$(<"$test_root/keyboard-invalid/stderr")" \
  'host Mac keyboard geometry is invalid'
[[ ! -e $test_root/keyboard-invalid/qemu.log ]] || \
  fail 'invalid keyboard geometry started QEMU'

# Exercise resource values through the real launcher and its QEMU boundary.
run_scenario resources 0 '' FAKE_HOST_CPUS=18 \
  OMARCHY_QEMU_GPU_CPUS=18 OMARCHY_QEMU_GPU_MEMORY_MIB=12288
assert_line_pair "$test_root/resources/qemu.log" -smp '18,sockets=1,cores=18,threads=1'
assert_line_pair "$test_root/resources/qemu.log" -m 12288M
assert_contains "$(<"$test_root/resources/stderr")" '18 vCPUs and 12 GiB RAM'

run_scenario resource-minimum 0 '' OMARCHY_QEMU_GPU_CPUS=4 OMARCHY_QEMU_GPU_MEMORY_MIB=2048
assert_line_pair "$test_root/resource-minimum/qemu.log" -smp '4,sockets=1,cores=4,threads=1'
assert_line_pair "$test_root/resource-minimum/qemu.log" -m 2048M
run_scenario resource-maximum-memory 0 '' OMARCHY_QEMU_GPU_MEMORY_MIB=45056
assert_line_pair "$test_root/resource-maximum-memory/qemu.log" -m 45056M
run_scenario smaller-host-defaults 0 '' FAKE_HOST_CPUS=6 FAKE_HOST_MEMORY_BYTES=7516192768
assert_line_pair "$test_root/smaller-host-defaults/qemu.log" -smp '6,sockets=1,cores=6,threads=1'
assert_line_pair "$test_root/smaller-host-defaults/qemu.log" -m 4096M

run_scenario too-many-cpus 1 '' OMARCHY_QEMU_GPU_CPUS=9
assert_contains "$(<"$test_root/too-many-cpus/stderr")" 'must be between 4 and 8'
[[ ! -s $test_root/too-many-cpus/storage.log ]] || fail 'invalid CPU count touched storage'
run_scenario too-much-memory 1 '' OMARCHY_QEMU_GPU_MEMORY_MIB=46080
assert_contains "$(<"$test_root/too-much-memory/stderr")" 'must leave the host at least 4096 MiB'
[[ ! -s $test_root/too-much-memory/storage.log ]] || fail 'invalid memory touched storage'
run_scenario insufficient-host-cpus 1 '' FAKE_HOST_CPUS=2
assert_contains "$(<"$test_root/insufficient-host-cpus/stderr")" 'at least four host CPUs'
run_scenario host-memory-reserve 1 '' FAKE_HOST_MEMORY_BYTES=8589934592 OMARCHY_QEMU_GPU_MEMORY_MIB=5120
assert_contains "$(<"$test_root/host-memory-reserve/stderr")" 'must leave the host at least 4096 MiB'

invalid_index=0
for invalid_resource in '' 0 -1 1.5 abc 08 1+2 18446744073709551620; do
  invalid_index=$((invalid_index + 1))
  for resource_key in OMARCHY_QEMU_GPU_CPUS; do
    scenario="invalid-resource-$resource_key-$invalid_index"
    run_scenario "$scenario" 1 '' "$resource_key=$invalid_resource"
    [[ ! -s $test_root/$scenario/storage.log ]] || fail 'malformed resource value touched storage'
    [[ ! -e $test_root/$scenario/qemu.log ]] || fail 'malformed resource value started QEMU'
  done
done

run_scenario nested-fallback 0 '' FAKE_QEMU_NESTED_STATUS=1
nested_fallback_qemu=$(<"$test_root/nested-fallback/qemu.log")
assert_line_pair "$test_root/nested-fallback/qemu.log" -machine \
  'virt,accel=hvf,gic-version=3'
assert_not_contains "$nested_fallback_qemu" virtualization=on
assert_not_contains "$nested_fallback_qemu" kernel-irqchip=on
assert_contains "$(<"$test_root/nested-fallback/nested.log")" probe

# Sequoia runs the updated graphics stack but must never probe or enter EL2.
for version in 15.0 15.3 15.7.7; do
  scenario="compatible-macos-$version"
  run_scenario "$scenario" 0 '' FAKE_MACOS_VERSION="$version"
  assert_line_pair "$test_root/$scenario/qemu.log" -machine \
    'virt,accel=hvf,gic-version=3'
  assert_not_contains "$(<"$test_root/$scenario/qemu.log")" virtualization=on
  assert_contains "$(<"$test_root/$scenario/qemu.log")" omarchy.virgl_dual_source=1
  [[ ! -e $test_root/$scenario/nested.log ]] || fail "macOS $version probed EL2"
done

# Reject unsupported hosts before storage changes, probes, or QEMU launches.
for version in 14.0 14.7.7; do
  scenario="unsupported-macos-$version"
  run_scenario "$scenario" 1 '' FAKE_MACOS_VERSION="$version"
  [[ ! -s $test_root/$scenario/storage.log ]] || fail "macOS $version touched storage"
  [[ ! -e $test_root/$scenario/qemu.log ]] || fail "macOS $version started QEMU"
  [[ ! -e $test_root/$scenario/nested.log ]] || fail "macOS $version probed EL2"
  assert_contains "$(<"$test_root/$scenario/stderr")" 'requires macOS 15 or newer'
done

for version in 26.0 26.1 27.0; do
  scenario="nested-macos-$version"
  run_scenario "$scenario" 0 '' FAKE_MACOS_VERSION="$version"
  assert_line_pair "$test_root/$scenario/qemu.log" -machine \
    'virt,gic-version=3,virtualization=on'
  assert_line_pair "$test_root/$scenario/qemu.log" -accel 'hvf,kernel-irqchip=on'
  assert_contains "$(<"$test_root/$scenario/nested.log")" probe
done

# An unavailable or unrecognized host version cannot satisfy the OS minimum.
for version in '' unknown; do
  scenario="unknown-macos-$version"
  run_scenario "$scenario" 1 '' FAKE_MACOS_VERSION="$version"
  [[ ! -s $test_root/$scenario/storage.log ]] || fail 'unknown macOS version touched storage'
  [[ ! -e $test_root/$scenario/qemu.log ]] || fail 'unknown macOS version started QEMU'
  [[ ! -e $test_root/$scenario/nested.log ]] || fail 'unknown macOS version probed EL2'
  assert_contains "$(<"$test_root/$scenario/stderr")" 'requires macOS 15 or newer'
done
run_scenario nested-version-failure 1 '' FAKE_MACOS_VERSION_STATUS=1
[[ ! -s $test_root/nested-version-failure/storage.log ]] || fail 'failed version query touched storage'
[[ ! -e $test_root/nested-version-failure/qemu.log ]] || fail 'failed version query started QEMU'
[[ ! -e $test_root/nested-version-failure/nested.log ]] || fail 'failed version query probed EL2'

run_scenario audio-shutdown-race 0 '' FAKE_AUDIO_EARLY_EXIT=1 FAKE_QEMU_LIFETIME=0.5
assert_not_contains "$(<"$test_root/audio-shutdown-race/stderr")" 'native audio bridge exited'
run_scenario audio-failure 1 '' FAKE_AUDIO_EARLY_EXIT=1 FAKE_QEMU_WAIT_FOR_TERMINATION=1
assert_contains "$(<"$test_root/audio-failure/stderr")" 'native audio bridge exited while QEMU was running'

# A clean guest shutdown may close the bridge before QEMU exits.
run_scenario audio-shutdown 0 '' FAKE_AUDIO_BRIDGE_LIFETIME=0.08 FAKE_QEMU_LIFETIME=0.45
run_scenario audio-failure 1 '' FAKE_AUDIO_BRIDGE_LIFETIME=0.08 FAKE_AUDIO_BRIDGE_STATUS=7 FAKE_QEMU_LIFETIME=10
assert_contains "$(<"$test_root/audio-failure/stderr")" 'native audio bridge exited while QEMU was running (status 7)'

run_scenario non-immersive 0 '' OMARCHY_QEMU_GPU_IMMERSIVE=0
non_immersive_qemu=$(<"$test_root/non-immersive/qemu.log")
assert_contains "$non_immersive_qemu" \
  'cocoa,gl=es,show-cursor=on,zoom-to-fit=on,full-screen=off,full-grab=on,immersive=off,swap-opt-cmd=off'

# An app update must not advertise its own locale capability for an older
# selected disk. Check both the rejection and a supported saved boot kit.
run_scenario locale-unsupported 1 '' OMARCHY_QEMU_GPU_LOCALE=zh_TW.UTF-8
assert_contains "$(<"$test_root/locale-unsupported/stderr")" 'does not support language selection'
[[ ! -f $test_root/locale-unsupported/qemu.log ]] || fail 'unsupported locale started QEMU'
saved_command_line=$(<"$persistent_root/boot/command-line")
printf '%s tryomarchy.locale_support=1\n' "$saved_command_line" >"$persistent_root/boot/command-line"
run_scenario locale-supported 0 '' OMARCHY_QEMU_GPU_LOCALE=zh_TW.UTF-8
assert_contains "$(<"$test_root/locale-supported/qemu.log")" 'tryomarchy.locale=zh_TW.UTF-8'
run_scenario locale-english 0 '' OMARCHY_QEMU_GPU_LOCALE=
assert_not_contains "$(<"$test_root/locale-english/qemu.log")" 'tryomarchy.locale='
printf '%s\n' "$saved_command_line" >"$persistent_root/boot/command-line"

# Simulate installing a newer app build after the first VM was created. The
# saved VM must be selected before the launcher even considers the absent new
# factory image.
/bin/rm -f "$guest/disk.raw"
printf 'previous boot console\n' >"$persistent_root/console.log"
run_scenario enabled 0 '' OMARCHY_QEMU_GPU_PORT_FORWARDS=tcp:2223:22
[[ -f $persistent_root/console.log.1 ]] || \
  fail 'expected the previous console log to be rotated to console.log.1'
[[ $(<"$persistent_root/console.log.1") == 'previous boot console' ]] || \
  fail 'console.log.1 did not retain the previous boot output'
enabled_qemu=$(<"$test_root/enabled/qemu.log")
assert_line_pair "$test_root/enabled/qemu.log" -netdev \
  'user,id=omarchy-net,hostfwd=tcp:127.0.0.1:2223-:22'
assert_line_pair "$test_root/enabled/qemu.log" -smbios 'type=11,value=tryomarchy.ssh_access=1'
assert_not_contains "$enabled_qemu" 0.0.0.0
assert_contains "$(<"$test_root/enabled/storage.log")" reuse
assert_not_contains "$(<"$test_root/enabled/storage.log")" materialize
assert_not_contains "$(<"$test_root/enabled/storage.log")" 'select persistent'
printf 'factory\n' >"$guest/disk.raw"

run_scenario preset 0 '' OMARCHY_QEMU_GPU_PORT_FORWARDS=tcp:2222:22
assert_line_pair "$test_root/preset/qemu.log" -netdev \
  'user,id=omarchy-net,hostfwd=tcp:127.0.0.1:2222-:22'
[[ $(grep -o 'tryomarchy.ssh_access=1' "$test_root/preset/qemu.log" | wc -l | tr -d ' ') == 1 ]] || \
  fail 'preset must append exactly one SSH activation token'

run_scenario udp-22 0 '' OMARCHY_QEMU_GPU_PORT_FORWARDS=udp:2224:22
udp_qemu=$(<"$test_root/udp-22/qemu.log")
assert_contains "$udp_qemu" 'hostfwd=udp:127.0.0.1:2224-:22'
assert_not_contains "$udp_qemu" tryomarchy.ssh_access

run_scenario unrelated 0 '' OMARCHY_QEMU_GPU_PORT_FORWARDS=tcp:8080:3000
unrelated_qemu=$(<"$test_root/unrelated/qemu.log")
assert_contains "$unrelated_qemu" 'hostfwd=tcp:127.0.0.1:8080-:3000'
assert_not_contains "$unrelated_qemu" tryomarchy.ssh_access

run_scenario mixed 0 '' \
  'OMARCHY_QEMU_GPU_PORT_FORWARDS=udp:5353:5353;tcp:22022:22;udp:2222:22'
mixed_qemu=$(<"$test_root/mixed/qemu.log")
assert_contains "$mixed_qemu" 'hostfwd=tcp:127.0.0.1:22022-:22'
assert_contains "$mixed_qemu" 'hostfwd=udp:127.0.0.1:2222-:22'
[[ $(grep -o 'tryomarchy.ssh_access=1' "$test_root/mixed/qemu.log" | wc -l | tr -d ' ') == 1 ]] || \
  fail 'mixed forwarding must append exactly one SSH activation token'

run_scenario ephemeral 0 --ephemeral OMARCHY_QEMU_GPU_PORT_FORWARDS=tcp:2224:22 \
  FAKE_HOST_CPUS=18 OMARCHY_QEMU_GPU_CPUS=18 OMARCHY_QEMU_GPU_MEMORY_MIB=12288
assert_line_pair "$test_root/ephemeral/qemu.log" -smp '18,sockets=1,cores=18,threads=1'
assert_line_pair "$test_root/ephemeral/qemu.log" -m 12288M
assert_contains "$(<"$test_root/ephemeral/qemu.log")" \
  'user,id=omarchy-net,hostfwd=tcp:127.0.0.1:2224-:22'
assert_contains "$(<"$test_root/ephemeral/qemu.log")" tryomarchy.ssh_access=1
assert_keyboard_lockstep "$test_root/ephemeral/qemu.log" iso
assert_contains "$(<"$test_root/ephemeral/storage.log")" 'select ephemeral'
assert_line_pair "$test_root/ephemeral/qemu.log" -bios "$firmware"

run_scenario malformed 1 '' OMARCHY_QEMU_GPU_PORT_FORWARDS=tcp:02222:22
[[ ! -s $test_root/malformed/storage.log ]] || fail 'malformed mapping touched storage'
assert_contains "$(<"$test_root/malformed/stderr")" 'canonical decimal'

run_scenario reset-only 0 --reset-storage-only \
  OMARCHY_QEMU_GPU_PORT_FORWARDS=tcp:2225:22 \
  FAKE_HOST_KEYBOARD_FAIL=1
assert_contains "$(<"$test_root/reset-only/storage.log")" 'select reset'
[[ ! -e $test_root/reset-only/qemu.log ]] || fail 'reset-only launch started QEMU'
assert_not_contains "$(<"$test_root/reset-only/stderr")" tryomarchy.ssh_access

# Dry runs must construct a bridge without requesting administrator access.
run_scenario bridge-preview 0 --ephemeral OMARCHY_QEMU_GPU_DRY_RUN=1 \
  OMARCHY_NETWORK_MODE=bridged OMARCHY_NETWORK_INTERFACE=en0 \
  OMARCHY_QEMU_GPU_PORT_FORWARDS=invalid-inactive-mapping
bridge_preview=$(<"$test_root/bridge-preview/stderr")
assert_contains "$bridge_preview" stream
assert_not_contains "$bridge_preview" hostfwd
assert_not_contains "$bridge_preview" tryomarchy.ssh_access=1
run_scenario bridge-ssh-preview 0 --ephemeral OMARCHY_QEMU_GPU_DRY_RUN=1 \
  OMARCHY_NETWORK_MODE=bridged OMARCHY_NETWORK_INTERFACE=en0 OMARCHY_NETWORK_BRIDGED_SSH=1
assert_contains "$(<"$test_root/bridge-ssh-preview/stderr")" tryomarchy.ssh_access=1
run_scenario bridge-invalid 1 '' OMARCHY_NETWORK_MODE=bridged OMARCHY_NETWORK_INTERFACE='../en0'
[[ ! -s $test_root/bridge-invalid/storage.log ]] || fail 'invalid bridge touched storage'
run_scenario bridge-reset 0 --reset-storage-only \
  OMARCHY_NETWORK_MODE=bridged OMARCHY_NETWORK_INTERFACE=en0 OMARCHY_NETWORK_WIFI_COMPATIBILITY=1
[[ ! -e $test_root/bridge-reset/qemu.log ]] || fail 'bridge reset started QEMU'

# Failed process inspection must never authorize deletion of another run.
stale_fixture=$(mktemp -d /private/tmp/omarchy-qemu-gpu.XXXXXX)
printf 'run-qemu-gpu:v1:999999:1' >"$stale_fixture/.run-qemu-gpu.owner"
printf 'keep' >"$stale_fixture/sentinel"
run_scenario unavailable-process-list 0 '' FAKE_PROCESS_INSPECTION_UNAVAILABLE=1
[[ -f $stale_fixture/sentinel ]] || fail 'failed process inspection removed another run'
assert_contains "$(<"$test_root/unavailable-process-list/stderr")" 'leaving other run directories intact'

# An early match must not close the pipe while the process snapshot is written.
run_scenario large-process-list 0 '' FAKE_LARGE_PROCESS_LIST=1
[[ -f $stale_fixture/sentinel ]] || fail 'large process list removed an active run'
assert_not_contains "$(<"$test_root/large-process-list/stderr")" 'Broken pipe'

# A guest that does not declare the UEFI boot ABI, or an app without its
# firmware, never reaches storage or QEMU.
/usr/bin/plutil -remove bootABI "$guest/launch.plist"
run_scenario no-boot-abi 1 ''
assert_contains "$(<"$test_root/no-boot-abi/stderr")" 'does not declare the UEFI boot ABI'
/usr/bin/plutil -insert bootABI -string uefi-gpt-v1 "$guest/launch.plist"
/bin/rm "$firmware"
run_scenario no-firmware 1 ''
assert_contains "$(<"$test_root/no-firmware/stderr")" 'missing bundled UEFI firmware'
for scenario in no-boot-abi no-firmware; do
  [[ ! -s $test_root/$scenario/storage.log ]] || fail "$scenario touched storage"
  [[ ! -e $test_root/$scenario/qemu.log ]] || fail "$scenario started QEMU"
done

printf 'run-qemu-ssh-contract.test: PASS\n'
