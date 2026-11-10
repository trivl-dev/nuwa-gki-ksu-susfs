#!/usr/bin/env bash
# 08_device_backup.sh - [OPTIONAL] back up the live partitions from an ALREADY ROOTED device.
# If the device is not rooted yet (first kernel install): do NOT run this - your rollback
# set is the stock images extracted into firmware/extracted/ (script 06).
# Run it from WSL2/Linux with adb, or copy the commands to Windows with platform-tools.
set -euo pipefail

DEST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/firmware/device-backup"
mkdir -p "$DEST"

command -v adb >/dev/null 2>&1 || { echo "ERROR: no adb in PATH. Install platform-tools."; exit 1; }
[ "$(adb get-state 2>/dev/null || true)" = "device" ] || { echo "ERROR: device is not online (adb devices)."; exit 1; }

# check root
if ! adb shell su -c 'id' 2>/dev/null | grep -q 'uid=0'; then
  echo "ERROR: device is not rooted (no su). Stopping - use firmware/extracted/ as the rollback set."
  exit 1
fi

TS="$(date +%Y%m%d-%H%M%S)"
for part in boot init_boot vendor_boot dtbo; do
  for slot in _a _b; do
    p="${part}${slot}"
    if adb shell su -c "ls /dev/block/by-name/$p" >/dev/null 2>&1; then
      echo "==> dd $p..."
      adb shell su -c "dd if=/dev/block/by-name/$p" > "$DEST/$p-$TS.img"
      ls -la "$DEST/$p-$TS.img"
    fi
  done
done

sha256sum "$DEST"/*.img > "$DEST/SHA256SUMS-$TS.txt"
echo "==> DONE: $DEST - copy it somewhere safe right away (rollback set for the running slot)."
