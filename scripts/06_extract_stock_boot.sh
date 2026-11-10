#!/usr/bin/env bash
# 06_extract_stock_boot.sh - verify the MD5 of the stock fastboot firmware and extract
# ONLY the images that are needed (~250 MB, no need to unpack the whole 8+ GB package).
# Pin source: docs/PINS.md section B.
#
# The stock ROM is supplied by the USER in firmware/ (by design - the kit does not ship it).
# Pinned build: OS3.0.303.0.WMBMIXM Global fastboot .tgz. Using a different HyperOS 3 build:
#   MD5_OVERRIDE=1 bash scripts/06_extract_stock_boot.sh
# (only if you are CERTAIN the file comes from the right source - the MD5 is the gate that
# catches a truncated download or the wrong build.)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FW="$ROOT/firmware"
STATE="$ROOT/state"
mkdir -p "$FW/extracted" "$STATE"

EXPECTED_MD5="d358f7a44683f5a74bf84842cf468ba1"

# ---------- 1. Locate the .tgz ----------
TGZ="${1:-}"
if [ -z "$TGZ" ]; then
  TGZ=$(find "$FW" -maxdepth 1 -name '*.tgz' -type f 2>/dev/null | head -1)
fi
[ -n "$TGZ" ] && [ -f "$TGZ" ] || {
  echo "ERROR: no firmware .tgz found."
  echo "     Put the stock ROM in $FW/ yourself (see firmware/README.md) or pass a path:"
  echo "     bash scripts/06_extract_stock_boot.sh /mnt/d/Download/nuwa_global_images_...tgz"
  exit 1
}
echo "==> Firmware: $TGZ ($(du -h "$TGZ" | cut -f1))"

# ---------- 2. Verify the MD5 ----------
ACTUAL_MD5=$(md5sum "$TGZ" | awk '{print $1}')
if [ "$ACTUAL_MD5" != "$EXPECTED_MD5" ]; then
  if [ "${MD5_OVERRIDE:-0}" = "1" ]; then
    echo "  [WARNING] MD5 does not match the pin but MD5_OVERRIDE=1 - continuing (you own the risk)."
    echo "             Actual: $ACTUAL_MD5 / Pin: $EXPECTED_MD5"
  else
    echo "ERROR: MD5 mismatch!"
    echo "  Actual  : $ACTUAL_MD5"
    echo "  Expected: $EXPECTED_MD5  (OS3.0.303.0.WMBMIXM Global fastboot)"
    echo "  The file is corrupt (partial download) or the wrong version - re-download it per"
    echo "  docs/PINS.md section B, or if this is a DIFFERENT HyperOS 3 build you are sure about:"
    echo "  MD5_OVERRIDE=1 bash scripts/06_extract_stock_boot.sh"
    exit 1
  fi
else
  echo "  [OK] MD5 matches the pin (OS3.0.303.0.WMBMIXM)"
fi
echo "$ACTUAL_MD5" > "$STATE/firmware.md5"

# ---------- 3. Selective extraction ----------
WANT='images/(boot|init_boot|vendor_boot|dtbo|vbmeta|recovery)\.img$'
echo "==> Listing images in the package..."
MEMBERS=$(tar -tzf "$TGZ" | grep -E "$WANT" || true)
if [ -z "$MEMBERS" ]; then
  echo "ERROR: no images/*.img found in the tar - unexpected package layout, stopping to investigate."
  exit 1
fi
echo "$MEMBERS" | sed 's/^/    /'
if ! echo "$MEMBERS" | grep -q 'images/boot\.img$'; then
  echo "ERROR: the package contains no boot.img - cannot repack/rollback. Stopping."
  exit 1
fi

echo "==> Extracting those images into firmware/extracted/ (~250 MB)..."
# shellcheck disable=SC2086
tar -xzf "$TGZ" -C "$FW/extracted" $MEMBERS

# ---------- 4. Extract the GKI config + vermagic from the stock kernel ----------
BOOT_IMG=$(find "$FW/extracted" -name boot.img | head -1)
[ -n "$BOOT_IMG" ] || { echo "ERROR: boot.img not found after extraction."; exit 1; }
# Scripts 02/04 use state/stock-<ver>.config as the build base. Extract it straight
# from boot.img so the kit always follows the OTA actually running, with no hardcoded config.
MB="$ROOT/tools/magiskboot/magiskboot"
[ -x "$MB" ] || { echo "ERROR: magiskboot missing - run scripts/03_fetch_toolchain.sh first."; exit 1; }
IKCONFIG="$ROOT/kernel-src/sm8550/scripts/extract-ikconfig"
[ -x "$IKCONFIG" ] || { echo "ERROR: kernel-src/sm8550/scripts/extract-ikconfig missing - run scripts/02_fetch_sources.sh first."; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
( cd "$TMP" && "$MB" unpack "$BOOT_IMG" >/dev/null ) || { echo "ERROR: magiskboot unpack failed"; exit 1; }
KERNEL_IMG="$TMP/kernel"
[ -s "$KERNEL_IMG" ] || { echo "ERROR: boot.img does not contain a kernel"; exit 1; }

VERMAGIC=$(strings -a "$KERNEL_IMG" | grep -m1 -E '^[0-9]+\.[0-9]+\.[0-9]+[^ ]* SMP .* aarch64$' || true)
[ -n "$VERMAGIC" ] || { echo "ERROR: no vermagic found in the stock kernel."; exit 1; }
KREL=${VERMAGIC%% *}
KVER=${KREL%%-*}
echo "    stock vermagic: $VERMAGIC"
echo "$VERMAGIC" > "$STATE/stock-vermagic.txt"

"$IKCONFIG" "$KERNEL_IMG" > "$TMP/stock.config" \
  || { echo "ERROR: extract-ikconfig failed - does the stock kernel embed IKCONFIG?"; exit 1; }
KVER_CFG=$(sed -n 's|^# Linux/arm64 \([0-9.]*\) Kernel Configuration$|\1|p' "$TMP/stock.config" | head -1)
[ "$KVER_CFG" = "$KVER" ] || {
  echo "ERROR: config says '$KVER_CFG' but vermagic says '$KVER' - inconsistent, stopping."
  exit 1
}
cp "$TMP/stock.config" "$STATE/stock-$KVER.config"
sha256sum "$STATE/stock-$KVER.config" > "$STATE/stock-$KVER.config.sha256"
echo "    [OK] state/stock-$KVER.config ($(wc -l < "$STATE/stock-$KVER.config") lines)"

# ---------- 5. Record the state ----------
find "$FW/extracted" -name '*.img' | sort | xargs sha256sum > "$STATE/stock-images.sha256"
ls -la "$(dirname "$BOOT_IMG")" | grep -E 'img' | sed 's/^/    /'

echo ""
echo "==> DONE. stock boot.img: $BOOT_IMG"
echo "    GKI config + vermagic: state/stock-$KVER.config, state/stock-vermagic.txt"
echo "    Copy firmware/extracted/ somewhere safe outside the workspace (rollback set)."
echo "    Next: bash scripts/04_build_kernel.sh (if you have not built yet)"
