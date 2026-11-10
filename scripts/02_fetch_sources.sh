#!/usr/bin/env bash
# 02_fetch_sources.sh - clone the ACK (GKI) kernel + KernelSU-Next at the pinned SHAs,
# then wire KSU-Next into the kernel tree. AnyKernel3 is cloned only with WITH_AK3=1.
#
# The kernel base is NOT a vendor OSS tree: the stock kernel of
# OS3.0.303.0.WMBMIXM is a Google GKI build from ACK `android13-5.15`
# (5.15.194, commit f4321180a397) - see docs/PINS.md and docs/BUILD-VERIFIED.md.
# The build config comes from the stock boot.img itself (state/stock-5.15.194.config),
# not from a vendor fragment.
# Idempotent: safe to run again.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/kernel-src"
STATE="$ROOT/state"
mkdir -p "$SRC" "$STATE"

# ---------- PIN (verified live 2026-11-10 - see docs/PINS.md) ----------
KERNEL_URL="https://android.googlesource.com/kernel/common"
KERNEL_SHA="f4321180a3973d19b626b3eef51871199e4e1fac"  # ACK android13-5.15 @ 5.15.194
KERNEL_VER="5.15.194"
STOCK_CONF="$STATE/stock-5.15.194.config"                # extracted from the stock boot.img (script 06)
KSU_URL="https://github.com/KernelSU-Next/KernelSU-Next.git"
KSU_TAG="v3.4.2"
KSU_SHA="4c706b5938665866ebe16944a481a7b91e3396af"      # KSU_VERSION 33355
KSU_REVCOUNT="3355"                                      # 30000 + rev-list count = 33355
AK3_URL="https://github.com/osm0sis/AnyKernel3.git"
AK3_BRANCH="master"
AK3_SHA="41f04bdb4ee30a44e429c2c1131d5e8bb32b15f1"

# clone_pin <dir> <url> <branch-or-tag> <sha> <shallow:0|1>
clone_pin() {
  local dir="$1" url="$2" ref="$3" sha="$4" shallow="$5"
  if [ ! -d "$dir/.git" ]; then
    echo "==> Cloning $url (@ $ref)..."
    if [ "$shallow" = "1" ]; then
      git clone --depth=1 -b "$ref" "$url" "$dir"
    else
      git clone -b "$ref" "$url" "$dir"
    fi
  fi
  if [ "$(git -C "$dir" rev-parse HEAD)" != "$sha" ]; then
    echo "==> HEAD differs from the pin - fetching the pinned SHA..."
    git -C "$dir" fetch origin "$sha" --depth=1 2>/dev/null \
      || git -C "$dir" fetch origin "$ref"
    git -C "$dir" checkout --detach "$sha"
  fi
  local actual
  actual=$(git -C "$dir" rev-parse HEAD)
  if [ "$actual" != "$sha" ]; then
    echo "ERROR: $dir is at $actual, pin is $sha. Upstream may have force-pushed."
    echo "     See docs/PINS.md - re-pin rules. Do NOT continue the build."
    exit 1
  fi
  echo "    [OK] $(basename "$dir") @ $actual"
}

# ---------- 1. Kernel base: ACK android13-5.15 @ commit (fetched by SHA) ----------
# ACK is a GKI monorepo; fetch the exact commit instead of cloning the branch head (the
# head moved on after the stock build date). googlesource supports fetching --depth=1 by SHA.
K="$SRC/sm8550"
if [ ! -d "$K/.git" ]; then
  echo "==> Initializing $KERNEL_URL..."
  mkdir -p "$K"
  git -C "$K" init -q
  git -C "$K" remote add origin "$KERNEL_URL"
fi
if [ "$(git -C "$K" rev-parse HEAD 2>/dev/null || true)" != "$KERNEL_SHA" ]; then
  echo "==> Fetching ACK commit $KERNEL_SHA (shallow)..."
  git -C "$K" fetch --depth=1 origin "$KERNEL_SHA" \
    || { echo "ERROR: cannot fetch $KERNEL_SHA from $KERNEL_URL"; exit 1; }
  git -C "$K" checkout --detach FETCH_HEAD >/dev/null 2>&1 \
    || { echo "ERROR: checkout of $KERNEL_SHA failed"; exit 1; }
fi
ACTUAL=$(git -C "$K" rev-parse HEAD)
[ "$ACTUAL" = "$KERNEL_SHA" ] || {
  echo "ERROR: kernel tree is at $ACTUAL, pin is $KERNEL_SHA."
  echo "     See docs/PINS.md - re-pin rules. Do NOT continue the build."
  exit 1
}
echo "$KERNEL_SHA" > "$STATE/kernel.sha"
echo "    [OK] sm8550 @ $ACTUAL"

# Assert the stock version (condition for stock modules to load: matching vermagic)
KVER=$(grep -E "^(VERSION|PATCHLEVEL|SUBLEVEL) =" "$K/Makefile" | awk '{print $3}' | paste -sd.)
[ "$KVER" = "$KERNEL_VER" ] || { echo "ERROR: kernel version is '$KVER', pin needs $KERNEL_VER - upstream moved?"; exit 1; }
echo "    [OK] kernel version: $KVER"

# The ACK tree has no nuwa vendor fragment (that fragment belongs to the MiCode tree).
# The build config comes from the stock boot.img itself; script 06 extracts that file.
[ -f "$K/arch/arm64/configs/gki_defconfig" ] || { echo "ERROR: missing arch/arm64/configs/gki_defconfig in ACK tree."; exit 1; }
[ -s "$STOCK_CONF" ] || {
  echo "ERROR: $STOCK_CONF is missing - the GKI config extracted from the stock boot.img."
  echo "     Run scripts/06_extract_stock_boot.sh first (needs the firmware in firmware/)."
  exit 1
}
grep -qx 'CONFIG_ARCH_QCOM=y' "$STOCK_CONF" || { echo "ERROR: $STOCK_CONF is not a GKI config (CONFIG_ARCH_QCOM=y missing)."; exit 1; }
grep -q "^# Linux/arm64 $KERNEL_VER Kernel Configuration" "$STOCK_CONF" || {
  echo "ERROR: $STOCK_CONF is not $KERNEL_VER - re-extract it from the stock boot.img."
  exit 1
}
echo "    [OK] gki_defconfig present + stock config $KERNEL_VER ($(wc -l < "$STOCK_CONF") lines)"

# ---------- 2. KernelSU-Next @ tag v3.4.2 - FULL HISTORY (required) ----------
# KSU_VERSION = 30000 + git rev-list --count HEAD (KSU-Next kernel/Kbuild).
# A shallow clone gives count=1 -> version 30001 -> the manager does NOT recognise the kernel.
KSU="$SRC/KernelSU-Next"
clone_pin "$KSU" "$KSU_URL" "$KSU_TAG" "$KSU_SHA" 0
echo "$KSU_SHA" > "$STATE/ksun.sha"

if [ -f "$KSU/.git/shallow" ]; then
  echo "==> KSU-Next is shallow - unshallowing to compute the correct version..."
  git -C "$KSU" fetch --unshallow
fi
COUNT=$(git -C "$KSU" rev-list --count HEAD)
[ "$COUNT" = "$KSU_REVCOUNT" ] || {
  echo "ERROR: git rev-list --count HEAD = $COUNT, pin requires $KSU_REVCOUNT."
  echo "     That skew makes KSU_VERSION = $((30000+COUNT)) instead of 33355 -> manager mismatch."
  echo "     Re-check the pin in docs/PINS.md."
  exit 1
}
echo "    [OK] KSU_VERSION will be $((30000+COUNT)) (rev-list count=$COUNT)"
echo "$((30000+COUNT))" > "$STATE/ksun.version"

# Assert the susfs LKM directory is present in the tree (script 05 needs it)
[ -f "$KSU/kernel/susfs/Makefile" ] || { echo "ERROR: kernel/susfs/ missing from KSU-Next - wrong pin?"; exit 1; }
[ -f "$KSU/kernel/Kconfig" ] || { echo "ERROR: kernel/Kconfig missing - cannot wire KSU in."; exit 1; }

# ---------- 3. Wire KernelSU-Next into the kernel tree (proven steps) ----------
cd "$K"

# 3a. symlink drivers/kernelsu -> ../../KernelSU-Next/kernel
rm -f drivers/kernelsu
ln -s ../../KernelSU-Next/kernel drivers/kernelsu
[ -L drivers/kernelsu ] && [ -d drivers/kernelsu ] || { echo "ERROR: drivers/kernelsu symlink is wrong."; exit 1; }

# 3b. drivers/Makefile: obj-$(CONFIG_KSU) += kernelsu/
if ! grep -q '^obj-\$(CONFIG_KSU) += kernelsu/' drivers/Makefile; then
  printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
fi
grep -q '^obj-\$(CONFIG_KSU) += kernelsu/' drivers/Makefile \
  || { echo "ERROR: drivers/Makefile is missing the KSU obj line."; exit 1; }

# 3c. drivers/Kconfig: source "drivers/kernelsu/Kconfig" (inserted before endmenu)
if ! grep -q '^source "drivers/kernelsu/Kconfig"' drivers/Kconfig; then
  sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig
fi
grep -q '^source "drivers/kernelsu/Kconfig"' drivers/Kconfig \
  || { echo "ERROR: drivers/Kconfig is missing the KSU source line."; exit 1; }

# 3d. Disable the hwid source line: Xiaomi stripped the drivers/misc/hwid directory from
#     OSS, but drivers/misc/Kconfig still sources the deleted file -> kconfig build fails.
#     (The stock module CONFIG_MI_HARDWARE_ID=m lives in vendor_dlkm - nothing is lost.)
if grep -q '^source "drivers/misc/hwid/Kconfig"' drivers/misc/Kconfig && [ ! -d drivers/misc/hwid ]; then
  sed -i 's|^source "drivers/misc/hwid/Kconfig"|# source "drivers/misc/hwid/Kconfig"  # directory stripped from the OSS tree (see docs/BUILD-VERIFIED.md)|' drivers/misc/Kconfig
fi
if grep -q '^source "drivers/misc/hwid/Kconfig"' drivers/misc/Kconfig && [ ! -d drivers/misc/hwid ]; then
  echo "ERROR: the hwid Kconfig source line for a missing directory is still present."; exit 1
fi
echo "    [OK] wiring: symlink + drivers/Makefile + drivers/Kconfig + hwid Kconfig"

# ---------- 4. (OPTIONAL) AnyKernel3 ----------
# Skipped by default: the kit flashes via boot.img (fastboot/Skyward), AK3 is not needed.
# Enable with WITH_AK3=1 (matches scripts/04_build_kernel.sh).
if [ "${WITH_AK3:-0}" = "1" ]; then
  clone_pin "$SRC/AnyKernel3" "$AK3_URL" "$AK3_BRANCH" "$AK3_SHA" 1
  echo "$AK3_SHA" > "$STATE/ak3.sha"
else
  echo "==> [4/4] AnyKernel3: skipped (WITH_AK3=0 - not needed for the boot.img flash path)"
fi

echo ""
echo "==> DONE (state: kernel.sha, ksun.sha, ksun.version, ak3.sha)."
echo "    Next: bash scripts/03_fetch_toolchain.sh"
