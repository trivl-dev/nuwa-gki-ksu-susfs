#!/usr/bin/env bash
# 05_build_susfs_lkm.sh - build susfs_guard_lkm.ko from kernel/susfs of KernelSU-Next v3.4.2
# as an external module against the kernel tree just built - vermagic + MODVERSIONS match 100%.
#
# Two NON-obvious details (learned from the real build on 2026-11-08 - see
# docs/BUILD-VERIFIED.md sections 4 and 6):
# 1. make Image only produces out/vmlinux.symvers; Module.symvers (needed for external
#    modules) is just a copy of it in a build without modules - copy it to the name
#    kbuild expects.
# 2. KBUILD_MODPOST_WARN=1 is INTENTIONAL: the susfs LKM deliberately leaves 6
#    non-exported kernel symbols undefined (task_work_add, init_mm, saved_boot_config,
#    dcache_clean_inval_poc, copy_to_kernel_nofault, __set_fixmap) - the ksud loader
#    resolves them via kallsyms right before loading. This is not an error.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K="$ROOT/kernel-src/sm8550"
KSU="$ROOT/kernel-src/KernelSU-Next"
SUSFS="$KSU/kernel/susfs"
TOOLS="$ROOT/tools"
BUILD="$ROOT/build"
STATE="$ROOT/state"
LOG="$STATE/susfs.log"
TS="$(date +%Y%m%d)"
mkdir -p "$BUILD" "$STATE"

[ -d "$K/.git" ] || { echo "ERROR: scripts/02_fetch_sources.sh has not been run"; exit 1; }
[ -x "$TOOLS/clang/bin/clang" ] || { echo "ERROR: scripts/03_fetch_toolchain.sh has not been run"; exit 1; }
[ -d "$SUSFS" ] || { echo "ERROR: missing $SUSFS - wrong KSU-Next pin."; exit 1; }
[ -s "$K/out/arch/arm64/boot/Image" ] || { echo "ERROR: no Image yet - run scripts/04_build_kernel.sh first."; exit 1; }
export PATH="$TOOLS/clang/bin:$PATH"

cd "$K"

# ---------- 1. Module.symvers (the proven workaround) ----------
if [ ! -f out/Module.symvers ] && [ -f out/vmlinux.symvers ]; then
  cp out/vmlinux.symvers out/Module.symvers
  echo "==> [1/4] created Module.symvers from vmlinux.symvers (make Image does not generate it)"
elif [ -f out/Module.symvers ]; then
  echo "==> [1/4] Module.symvers already present"
else
  echo "ERROR: no out/vmlinux.symvers - did the kernel build finish?"; exit 1
fi

# ---------- 2. modules_prepare: scripts/module.lds ----------
# make Image does NOT generate scripts/module.lds (only the modules/prepare target
# does); Makefile.modfinal needs that file when linking a .ko. This tree only builds
# Image (per section 6.7 of BUILD-VERIFIED), so modules_prepare has to run once.
# Idempotent: only runs while the file is missing (avoids touching config mtimes).
if [ ! -f out/scripts/module.lds ]; then
  echo "==> [2/4] out/scripts/module.lds missing - running modules_prepare..."
  make -j2 O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 HOSTCC=gcc LOCALVERSION= modules_prepare >> "$LOG" 2>&1 \
    || { tail -20 "$LOG"; echo "ERROR: modules_prepare failed (log: $LOG)"; exit 1; }
fi
[ -f out/scripts/module.lds ] || { echo "ERROR: out/scripts/module.lds still missing after modules_prepare."; exit 1; }

# ---------- 3. External module build ----------
echo "==> [3/4] build susfs_guard_lkm.ko (KBUILD_MODPOST_WARN=1 - 6 symbols undefined by design)"
make -j2 O=out M="$SUSFS" ARCH=arm64 LLVM=1 LLVM_IAS=1 HOSTCC=gcc LOCALVERSION= KBUILD_MODPOST_WARN=1 \
  > "$LOG" 2>&1 || { tail -40 "$LOG"; echo "ERROR: susfs build failed (log: $LOG)"; exit 1; }

KO="$SUSFS/susfs_guard_lkm.ko"
[ -s "$KO" ] || { echo "ERROR: could not produce $KO"; exit 1; }
file "$KO" | grep -q "ARM aarch64" || { echo "ERROR: $KO is not an aarch64 ELF."; exit 1; }

# ---------- 4. Verify vermagic matches the kernel just built ----------
echo "==> [4/4] verify vermagic"
EXPECT_VERMAGIC=$(cat "$STATE/stock-vermagic.txt")
[ -n "$EXPECT_VERMAGIC" ] || { echo "ERROR: missing state/stock-vermagic.txt - run scripts/06_extract_stock_boot.sh"; exit 1; }
VER=$(strings "$KO" | grep -m1 "vermagic=" || true)
echo "    $VER"
# Compare in bash (do not pipe through grep -q: pipefail + SIGPIPE gives false failures)
[ "$VER" = "vermagic=$EXPECT_VERMAGIC" ] \
  || { echo "ERROR: LKM vermagic '$VER' != stock 'vermagic=$EXPECT_VERMAGIC' - kernel/module mismatch!"; exit 1; }
echo "    [OK] LKM vermagic matches stock"

cp "$KO" "$BUILD/susfs_guard_lkm.ko"
sha256sum "$BUILD/susfs_guard_lkm.ko" >> "$STATE/build-$TS.sha256"

echo ""
echo "==> DONE: build/susfs_guard_lkm.ko ($(du -h "$BUILD/susfs_guard_lkm.ko" | cut -f1))"
echo ""
echo "HOW TO LOAD IT ON THE DEVICE (read docs/FLASH-SAFETY.md first):"
echo "  - Do not load it with a plain insmod - the module needs the ksud loader to resolve"
echo "    6 symbols through kallsyms. Install the KernelSU-Next manager v3.4.2 -> Settings ->"
echo "    SUSFS -> enable auto-load (the manager ships an asset with the right android13-5.15 KMI)."
echo "  - Manual load with ksud: /data/adb/ksu/bin/ksud susfs load"
echo "  - This self-built .ko is for reference/advanced use (replacing the bundled asset)."
