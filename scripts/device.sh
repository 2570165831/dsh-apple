#!/bin/bash
# Shared simulator device-set plumbing.
#
# CoreSimulatorService cannot write device data to an external volume: it needs
# the "removable volumes" TCC grant, which only the user can click. The B-stage
# workaround for this machine is to keep a custom `--set` path inside the task
# directory but make it a symlink to a cache directory on the internal disk.
# Same shape as the TASK asks for, and the reason is a TCC limitation, not a
# choice.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export SIMSET="$ROOT/simdevices"
# Under the user's own cache directory, which is where CoreSimulator can
# actually write; $HOME rather than a literal path so this works for anyone.
export SIMCACHE="$HOME/Library/Caches/dsh-ios-port-E/simdevices"
export BUNDLE_ID="local.dshportc.app"
export APP_PATH="$ROOT/DerivedData/Build/Products/Debug-iphonesimulator/DSHPortC.app"

# ---------------------------------------------------------------- which device
# Step 10 added a second device to this set: one iPad, so the same app can be
# measured in both idioms. Everything that used to hard-code the phone now takes
# `DSHPORTE_DEVICE`, and the phone stays the default so every earlier script and
# report keeps meaning what it meant.
#
#   DSHPORTE_DEVICE=phone  (default)  dsh-portE-iPhone     iPhone 17
#   DSHPORTE_DEVICE=ipad              dsh-portE-iPad       iPad Air 11-inch (M4)
#   DSHPORTE_DEVICE=phone-bg          dsh-portE-iPhone-bg  iPhone 17
#   DSHPORTE_DEVICE=phone-files       dsh-portE-iPhone-files  iPhone 17
#   DSHPORTE_DEVICE=phone-polish      dsh-portE-iPhone-polish  iPhone 17
#
# `phone-bg` is step 13's device: a THIRD iPhone, so the background-continuation
# work can drive its own simulator while step 11 keeps using `dsh-portE-iPhone`
# in the main checkout. It is deliberately separate from `phone` rather than an
# alias: the two are running different builds at the same time and sharing one
# would make every measurement ambiguous. Like the iPad it is never created
# implicitly — a typo'd name must not silently mint a device, and a missing one
# is a hard error that says how to make it.
#
# The iPad was created once, by hand, in the same custom set; nothing here
# creates it implicitly. `device_udid` still auto-creates the PHONE because that
# is what the earlier steps relied on, but an unknown value is a hard error
# rather than a silent fallback to the phone — measuring the wrong device while
# the log says "ipad" is the kind of mistake this whole file exists to avoid.
DEVICE_KIND="${DSHPORTE_DEVICE:-phone}"
case "$DEVICE_KIND" in
  phone|iphone)
    DEVICE_KIND="phone"
    DEVICE_NAME="dsh-portE-iPhone"
    DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17"
    ;;
  ipad)
    DEVICE_NAME="dsh-portE-iPad"
    DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPad-Air-11-inch-M4"
    ;;
  phone-bg|iphone-bg)
    DEVICE_KIND="phone-bg"
    DEVICE_NAME="dsh-portE-iPhone-bg"
    DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17"
    ;;
  phone-files|iphone-files)
    DEVICE_KIND="phone-files"
    DEVICE_NAME="dsh-portE-iPhone-files"
    DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17"
    ;;
  phone-polish|iphone-polish)
    DEVICE_KIND="phone-polish"
    DEVICE_NAME="dsh-portE-iPhone-polish"
    DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17"
    ;;
  *)
    echo "device.sh: unknown DSHPORTE_DEVICE '$DEVICE_KIND' (use phone, ipad, phone-bg, phone-files or phone-polish)" >&2
    exit 2
    ;;
esac
export DEVICE_KIND DEVICE_NAME DEVICE_TYPE
RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-27-0"

ensure_set() {
  mkdir -p "$SIMCACHE"
  if [ ! -e "$SIMSET" ]; then ln -sfn "$SIMCACHE" "$SIMSET"; fi
}

# Print the UDID of the task's own device, creating it if needed.
device_udid() {
  ensure_set
  local udid all
  # Match the device name after the leading indentation `simctl` prints. An
  # `index($0, ...) == 1` test silently never matches because of that indent,
  # which is exactly how an earlier run created a second device with the same
  # name instead of reusing the first.
  all=$(xcrun simctl --set "$SIMSET" list devices 2>/dev/null \
    | grep -F "$DEVICE_NAME (" \
    | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
  udid=$(printf '%s\n' "$all" | head -n 1)
  if [ "$(printf '%s\n' "$all" | grep -c .)" -gt 1 ]; then
    echo "WARNING: $DEVICE_NAME exists more than once:" >&2
    printf '%s\n' "$all" | sed 's/^/  /' >&2
    echo "  using the first; delete the extras with: xcrun simctl --set $SIMSET delete <udid>" >&2
  fi
  if [ -z "$udid" ]; then
    # Only the phone is created implicitly. The iPad costs a second of setup and
    # a copy of the runtime's data skeleton, and step 10's task says exactly one
    # iPad and no others — a typo'd name must not silently mint another one.
    # `phone-bg` is in the same category as the iPad for the same reason: step
    # 13's task says the device already exists, so a missing one is a fact to
    # report, not something to paper over with a fresh device that would then
    # carry a different data container than the one under test.
    if [ "$DEVICE_KIND" != "phone" ]; then
      echo "device.sh: $DEVICE_NAME does not exist in $SIMSET and this script will not create it" >&2
      echo "  create it deliberately: xcrun simctl --set $SIMSET create $DEVICE_NAME $DEVICE_TYPE $RUNTIME" >&2
      exit 1
    fi
    udid=$(xcrun simctl --set "$SIMSET" create "$DEVICE_NAME" "$DEVICE_TYPE" "$RUNTIME")
  fi
  printf '%s' "$udid"
}

# Boot it and wait until it is actually usable.
boot_device() {
  local udid="$1"
  local state
  state=$(xcrun simctl --set "$SIMSET" list devices | awk -v u="$udid" '$0 ~ u {gsub(/[()]/,"",$3); print $3; exit}')
  if [ "$state" != "Booted" ]; then
    xcrun simctl --set "$SIMSET" boot "$udid" >/dev/null 2>&1 || true
    xcrun simctl --set "$SIMSET" bootstatus "$udid" >/dev/null 2>&1 || true
  fi
}

shutdown_device() {
  local udid="${1:-}"
  [ -n "$udid" ] || return 0
  xcrun simctl --set "$SIMSET" terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl --set "$SIMSET" shutdown "$udid" >/dev/null 2>&1 || true
}

app_container_data() {
  xcrun simctl --set "$SIMSET" get_app_container "$1" "$BUNDLE_ID" data
}
