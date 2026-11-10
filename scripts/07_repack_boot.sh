#!/usr/bin/env bash
# 07_repack_boot.sh - swap the new kernel into the stock boot.img with magiskboot (x86_64).
# This keeps header v4 + cmdline + everything else from stock - the safest option on a
# stock device (docs/BUILD-VERIFIED.md section 7).
# nuwa: boot.img holds an uncompressed arm64 Image and NO ramdisk (moved to
# init_boot since Android 13); the DTB lives in vendor_boot -> only `kernel` changes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
STATE="$ROOT/state"
MB="$ROOT/tools/magiskboot/magiskboot"
TS="$(date +%Y%m%d)"

# ---------- 1. Inputs ----------
IMG=$(ls -t "$BUILD"/Image-* 2>/dev/null | head -1)
[ -n "$IMG" ] && [ -f "$IMG" ] || { echo "ERROR: no build/Image-YYYYMMDD - run scripts/04_build_kernel.sh"; exit 1; }
[ -x "$MB" ] || { echo "ERROR: magiskboot missing - run scripts/03_fetch_toolchain.sh"; exit 1; }
STOCK=$(find "$ROOT/firmware/extracted" -name boot.img 2>/dev/null | head -1)
[ -n "$STOCK" ] && [ -f "$STOCK" ] || { echo "ERROR: no stock boot.img yet - run scripts/06_extract_stock_boot.sh (needs the ROM in firmware/)"; exit 1; }

# Guard: the Image must carry the exact stock vermagic (prevents repacking a stale
# artifact such as build/archive-5.15.41/Image-*). state/stock-vermagic.txt is required.
[ -s "$STATE/stock-vermagic.txt" ] || { echo "ERROR: missing state/stock-vermagic.txt - run scripts/06_extract_stock_boot.sh"; exit 1; }
EXPECT_VERMAGIC=$(cat "$STATE/stock-vermagic.txt")
case "$(basename "$IMG")" in
  *archive*) echo "ERROR: picked an Image from the archive ($IMG) - not flashing an old build."; exit 1;;
esac
STRS="$STATE/strings-image.txt"
strings -a "$IMG" > "$STRS" || { echo "ERROR: strings failed on $IMG"; exit 1; }
grep -qxF "$EXPECT_VERMAGIC" "$STRS" \
  || { echo "ERROR: '$IMG' does NOT contain the stock vermagic:"; echo "     '$EXPECT_VERMAGIC'"; echo "     -> wrong Image version, NOT repacking."; exit 1; }
echo "    [OK] Image vermagic matches stock: $EXPECT_VERMAGIC"

OUTIMG="$BUILD/nuwa-ksun-susfs_boot_$TS.img"
WORK="$BUILD/repack"
rm -rf "$WORK" && mkdir -p "$WORK"
cd "$WORK"

# ---------- 2. Unpack the stock boot.img ----------
echo "==> Unpacking stock boot.img..."
cp "$STOCK" stock-boot.img
"$MB" unpack stock-boot.img > unpack.log 2>&1 || { cat unpack.log; echo "ERROR: magiskboot unpack failed - unexpected stock boot.img?"; exit 1; }
# nuwa stock boot.img: NO ramdisk (it lives in init_boot). If unpack produces a ramdisk
# -> the stock file comes from the wrong source - stop and investigate instead of blind repacking.
if [ -s ramdisk.cpio ]; then
  echo "ERROR: stock boot.img contains a ramdisk (expected none - nuwa keeps its ramdisk in init_boot)."
  echo "     The stock file is from the wrong source/build. Stopping - check firmware/README.md + docs/PINS.md B."
  exit 1
fi
[ -s kernel ] || { echo "ERROR: magiskboot unpack produced no kernel file - unexpected stock boot.img."; exit 1; }
head -3 unpack.log | sed 's/^/    /'

# ---------- 3. Replace the kernel ----------
# New kernel: raw arm64 Image (uncompressed) - exactly the stock format.
# magiskboot repack keeps the stock header v4, cmdline, page size and dtb.
echo "==> Replacing kernel: $IMG ($(du -h "$IMG" | cut -f1))"
cp "$IMG" kernel
"$MB" repack stock-boot.img "$OUTIMG" > repack.log 2>&1 || { cat repack.log; echo "ERROR: magiskboot repack failed"; exit 1; }

# ---------- 4. Verification ----------
[ -s "$OUTIMG" ] || { echo "ERROR: could not create $OUTIMG"; exit 1; }
STOCK_MB=$(( $(stat -c%s stock-boot.img) / 1024 / 1024 ))
NEW_MB=$(( $(stat -c%s "$OUTIMG") / 1024 / 1024 ))
echo "==> Stock: ${STOCK_MB} MB -> Custom: ${NEW_MB} MB (difference = kernel size difference)"
if [ "$NEW_MB" -gt $(( STOCK_MB + 40 )) ]; then
  echo "ERROR: boot-custom is unusually larger than stock - stopping, investigate."
  exit 1
fi
# Round-trip: unpack the custom image again to confirm the new kernel is inside
"$MB" unpack "$OUTIMG" > verify.log 2>&1 || { cat verify.log; echo "ERROR: could not unpack the custom boot again - corrupt file."; exit 1; }
cmp -s kernel "$IMG" || { echo "ERROR: kernel inside the custom boot != the built Image - bad repack!"; exit 1; }
echo "    [OK] round-trip: kernel inside boot.img = built Image (byte compare)"

sha256sum "$OUTIMG" >> "$STATE/build-$TS.sha256"
sha256sum "$OUTIMG" stock-boot.img > "$STATE/repack-$TS.sha256"

echo ""
echo "==> DONE: $OUTIMG"
echo ""
echo "NEXT (Windows side - read docs/FLASH-SAFETY.md before doing this):"
echo "  1. Copy boot-custom + stock boot.img (rollback) to a Windows drive"
echo "  2. Test-boot FIRST:   adb reboot bootloader && fastboot boot nuwa-ksun-susfs_boot_$TS.img"
echo "  3. Check touch/Wi-Fi/cellular/camera/fingerprint - only flash once all pass:"
echo "     fastboot flash boot nuwa-ksun-susfs_boot_$TS.img && fastboot reboot"
