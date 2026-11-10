#!/usr/bin/env bash
# verify_stock_kmi.sh -- compare the KMI symbol CRCs of a stock module
# (vendor_dlkm) against the freshly built kernel. This is the "life or death"
# check before flashing: on a CRC mismatch the stock module will not load even
# if vermagic matches.
#
# Usage:
#   bash scripts/verify_stock_kmi.sh /path/to/module_stock.ko
#
# Get a stock module from the device (while running the stock kernel):
#   adb shell 'ls /vendor_dlkm/lib/modules | head'
#   adb pull /vendor_dlkm/lib/modules/<name>.ko
#
# The script compares:
#   1. the .ko vermagic  == state/stock-vermagic.txt (the stock string)
#   2. every __crc_<sym> imported by the .ko == the CRC in out/Module.symvers
#      (or out/vmlinux.symvers) of the freshly built kernel.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K="$ROOT/kernel-src/sm8550"
STATE="$ROOT/state"

KO="${1:-}"
[ -n "$KO" ] && [ -f "$KO" ] || {
  echo "Usage: bash scripts/verify_stock_kmi.sh <module_stock.ko>"
  exit 1
}
[ -s "$STATE/stock-vermagic.txt" ] || { echo "ERROR: missing state/stock-vermagic.txt -- run scripts/06_extract_stock_boot.sh"; exit 1; }

SYMVERS="$K/out/Module.symvers"
[ -f "$SYMVERS" ] || SYMVERS="$K/out/vmlinux.symvers"
[ -f "$SYMVERS" ] || { echo "ERROR: missing out/Module.symvers / out/vmlinux.symvers -- build the kernel first."; exit 1; }

# ---------- 1. Vermagic ----------
# IMPORTANT: with CONFIG_MODVERSIONS the kernel uses same_magic() and compares
# only the part AFTER the first space of vermagic ("SMP preempt mod_unload
# modversions aarch64") -- the version prefix is ignored. Real-world evidence:
# 328 stock modules in the vendor_boot of OS3.0.303 record vermagic 5.15.78 yet
# still load on the stock 5.15.194 kernel. This script therefore compares the
# tail only, while the real compatibility is decided by the CRCs (step 2). The
# kernel built by this kit still keeps the 5.15.194 prefix so it matches
# exactly (we do not rely on the kernel ignoring the prefix).
EXPECT_VERMAGIC=$(cat "$STATE/stock-vermagic.txt")
if command -v modinfo >/dev/null 2>&1; then
  KO_VERMAGIC=$(modinfo -F vermagic "$KO" 2>/dev/null | sed 's/[[:space:]]*$//')
else
  KO_VERMAGIC=$(strings -a "$KO" | grep -m1 -E '^[0-9]+\.[0-9]+\.[0-9]+[^ ]* SMP .* aarch64$' || true)
fi
[ -n "$KO_VERMAGIC" ] || { echo "ERROR: cannot read vermagic from $KO"; exit 1; }
TAIL_KO=${KO_VERMAGIC#* }
TAIL_EXPECT=${EXPECT_VERMAGIC#* }
if [ "$TAIL_KO" != "$TAIL_EXPECT" ]; then
  echo "ERROR: vermagic tail DIFFERS -- the module will definitely be rejected"
  echo "  module: $KO_VERMAGIC"
  echo "  stock : $EXPECT_VERMAGIC"
  exit 1
fi
if [ "$KO_VERMAGIC" = "$EXPECT_VERMAGIC" ]; then
  echo "[OK] vermagic matches exactly: $KO_VERMAGIC"
else
  echo "[OK] vermagic tail matches: '$TAIL_KO' (module records prefix '${KO_VERMAGIC%% *}' -- the kernel ignores the prefix when MODVERSIONS)"
fi

# ---------- 2. Symbol CRCs ----------
# MODVERSIONS modules store CRCs in the __versions section: each entry is 64
# bytes (unsigned long crc + char name[56], arm64 little-endian).
TMP=$(mktemp)
TMPBIN=$(mktemp)
trap 'rm -f "$TMP" "$TMPBIN"' EXIT
# Distro GNU objcopy (x86_64) usually cannot read aarch64 ELF; use the
# llvm-objcopy shipped with the pinned clang (scripts/03_fetch_toolchain.sh).
OBJCOPY="$ROOT/tools/clang/bin/llvm-objcopy"
if [ ! -x "$OBJCOPY" ]; then
  OBJCOPY=$(command -v llvm-objcopy || true)
fi
[ -n "$OBJCOPY" ] && [ -x "$OBJCOPY" ] \
  || { echo "ERROR: llvm-objcopy not found. Run scripts/03_fetch_toolchain.sh first."; exit 1; }
"$OBJCOPY" -O binary --only-section=__versions "$KO" "$TMPBIN" 2>/dev/null \
  || { echo "ERROR: cannot extract the __versions section from $KO"; exit 1; }
python3 - "$TMPBIN" > "$TMP" <<'PYEOF'
import struct, sys
data = open(sys.argv[1], "rb").read()
if len(data) % 64:
    sys.exit("ERROR: __versions size is not a multiple of 64 bytes")
for off in range(0, len(data), 64):
    crc, name = struct.unpack_from("<Q56s", data, off)
    name = name.split(b"\0", 1)[0].decode("ascii", "replace")
    print(f"{name} {crc:08x}")
PYEOF

N=$(wc -l < "$TMP")
[ "$N" -gt 0 ] || { echo "ERROR: module has no __versions entries -- not a MODVERSIONS module?"; exit 1; }
echo "==> Module imports $N symbols with CRCs; comparing against $(basename "$SYMVERS")..."

awk -v ko="$TMP" '
  BEGIN {
    while ((getline line < ko) > 0) {
      split(line, a, " ");
      crc[a[1]] = a[2];
    }
    close(ko);
  }
  {
    sym = $2;
    v = $1; sub(/^0x/, "", v); v = tolower(v);
    if (sym in crc) {
      seen[sym] = 1;
      if (crc[sym] != v) {
        printf "  [MISMATCH] %-50s stock=%s build=%s\n", sym, crc[sym], v;
        bad++;
      } else {
        ok++;
      }
    }
  }
  END {
    for (s in crc) if (!(s in seen)) { printf "  [MODULE] %-49s stock=%s (provided by another vendor module)\n", s, crc[s]; missing++; }
    printf "RESULT ok=%d bad=%d missing=%d\n", ok, bad, missing;
    exit (bad) ? 1 : 0;
  }
' "$SYMVERS" | tee "$STATE/kmi-check.log"

grep -q '^RESULT ok=' "$STATE/kmi-check.log" || { echo "ERROR: cannot read symvers."; exit 1; }
if grep -qE '^  \[MISMATCH\]' "$STATE/kmi-check.log"; then
  echo "ERROR: KMI does NOT match -- do NOT flash this kernel."
  exit 1
fi
echo "[OK] all KMI CRCs match the stock modules ($(tail -1 "$STATE/kmi-check.log"))"
echo "     ([MODULE] = symbol exported by another vendor module -- not an error)"
