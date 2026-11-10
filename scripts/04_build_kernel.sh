#!/usr/bin/env bash
# 04_build_kernel.sh - build a GKI 5.15.194 Image matching the OS3.0.303 stock kernel.
#
# Baseline (re-pinned 2026-11-10):
#   - kernel: ACK android13-5.15 @ f4321180a397 (5.15.194) - the exact commit Google
#     used to build the stock kernel (see docs/PINS.md + BUILD-VERIFIED section 6).
#   - config: extracted from the stock boot.img itself (state/stock-5.15.194.config),
#     NOT the MiCode gki_defconfig/vendor fragment.
#   - only delta: KSU=y, ThinLTO, BTF ON (mandatory for KMI), TRIM_UNUSED_KSYMS off,
#     LOCALVERSION = the exact stock suffix (vermagic must match character by character).
#
# Every decision (ThinLTO because of the RAM budget, BTF ON because disabling it
# changes struct module and therefore most KMI CRCs, LOCALVERSION matching stock)
# is explained in docs/BUILD-VERIFIED.md sections 3-4.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K="$ROOT/kernel-src/sm8550"
TOOLS="$ROOT/tools"
BUILD="$ROOT/build"
STATE="$ROOT/state"
LOG="$STATE/build.log"
TS="$(date +%Y%m%d)"
mkdir -p "$BUILD" "$STATE"

STOCK_CONF="$STATE/stock-5.15.194.config"
KREL_SUFFIX="-android13-8-00019-gf4321180a397-ab15212794"
EXPECT_UTS="5.15.194$KREL_SUFFIX"
STOCK_KERNEL_SZ=47577600   # KERNEL_SZ of the stock boot.img (reference)

[ -d "$K/.git" ] || { echo "ERROR: scripts/02_fetch_sources.sh has not been run"; exit 1; }
[ -x "$TOOLS/clang/bin/clang" ] || { echo "ERROR: scripts/03_fetch_toolchain.sh has not been run"; exit 1; }
[ -s "$STOCK_CONF" ] || {
  echo "ERROR: missing $STOCK_CONF - the GKI config extracted from the stock boot.img."
  echo "     Run scripts/06_extract_stock_boot.sh first."
  exit 1
}
export PATH="$TOOLS/clang/bin:$PATH"

# Job count: capped by RAM by default (ThinLTO + KASAN + DEBUG_INFO are RAM hungry).
# Can be forced with JOBS_OVERRIDE (for example JOBS_OVERRIDE=6). Note: more jobs =
# more RAM; the BTF step (pahole) needs headroom - add swap first on a small machine.
JOBS=$(nproc)
RAM_GB=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}')
SWAP_GB=$(free -g 2>/dev/null | awk '/^Swap:/{print $2}')
if [ -n "${JOBS_OVERRIDE:-}" ]; then
  JOBS="$JOBS_OVERRIDE"
  echo "==> JOBS_OVERRIDE=$JOBS_OVERRIDE -> using -j$JOBS (RAM ${RAM_GB:-?} GB + swap ${SWAP_GB:-0} GB)"
else
  if [ -n "$RAM_GB" ] && [ "$RAM_GB" -gt 0 ] && [ $((RAM_GB / 2)) -lt "$JOBS" ]; then
    JOBS=$((RAM_GB / 2))
  fi
  [ "$JOBS" -lt 2 ] && JOBS=2
  echo "==> Machine: $(nproc) cores, ${RAM_GB:-?} GB RAM + ${SWAP_GB:-0} GB swap -> using -j$JOBS"
fi
if [ "${RAM_GB:-0}" -lt 10 ] && [ "${SWAP_GB:-0}" -lt 8 ]; then
  echo "    [WARNING] Low RAM+swap: the BTF step (pahole) may OOM. Add at least 8 GB of swap."
fi

# LOCALVERSION= (empty) is MANDATORY on the command line: scripts/setlocalversion
# only strips the trailing '+' when the make LOCALVERSION variable is set (even if
# it is empty). The tree carries the KSU wiring so git is always dirty; without this
# variable utsrelease becomes '...-ab15212794+' -> vermagic no longer matches stock.
# (CONFIG_LOCALVERSION still keeps the stock suffix.)
MK="make -j$JOBS O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 HOSTCC=gcc LOCALVERSION="

cd "$K"
mkdir -p out

# ---------- 1. Base config: stock GKI 5.15.194 ----------
echo "==> [1/8] base config: stock GKI 5.15.194 (extracted from boot.img)"
grep -q "^# Linux/arm64 5.15.194 Kernel Configuration" "$STOCK_CONF" \
  || { echo "ERROR: $STOCK_CONF is not a GKI 5.15.194 config - re-extract from the stock boot.img."; exit 1; }
cp "$STOCK_CONF" out/.config
echo "    [OK] $(wc -l < out/.config) lines, stock LOCALVERSION=''"

# ---------- 2. Config delta ----------
echo "==> [2/8] delta: KSU=y, ThinLTO, BTF ON (mandatory for KMI), TRIM off, LOCALVERSION=stock"
./scripts/config --file out/.config -e KSU
./scripts/config --file out/.config -d LTO_CLANG_FULL -e LTO_CLANG_THIN
# BTF MUST STAY ON: CONFIG_DEBUG_INFO_BTF_MODULES adds 2 fields to struct module
# (btf_data_size, btf_data). genksyms hashes structs TRANSITIVELY, so struct module
# leaks into the CRC of most KMI symbols (sk_buff->net_device->device->device_driver->
# module), shifting ~63% of all CRCs -> vendor modules are refused -> BOOTLOOP.
# This is the actual root cause of the 2026-11-08 bootloop (not just the version
# prefix). Verify: the module_layout CRC must be 0x0222dd63 (abi_gki_aarch64 xml).
./scripts/config --file out/.config -e DEBUG_INFO_BTF
./scripts/config --file out/.config -e DEBUG_INFO_BTF_MODULES
./scripts/config --file out/.config -e MODULE_ALLOW_BTF_MISMATCH
./scripts/config --file out/.config -d TRIM_UNUSED_KSYMS
./scripts/config --file out/.config --set-str UNUSED_KSYMS_WHITELIST ""
./scripts/config --file out/.config --set-str LOCALVERSION "$KREL_SUFFIX"
./scripts/config --file out/.config -d LOCALVERSION_AUTO
$MK olddefconfig >> "$LOG" 2>&1 || { tail -20 "$LOG"; echo "ERROR: olddefconfig failed"; exit 1; }

# ---------- 2b. GUARD: config changed => a clean build is MANDATORY ----------
# kbuild does NOT rebuild every object when .config changes (it only tracks the
# include/config/<SYMBOL> files each object depends on). Stale objects keep the old
# genksyms CRC -> the kernel mixes old and new CRCs -> silently broken KMI even when
# the config itself is correct.
# Real lesson from 2026-11-10: BTF was enabled but 326 objects were still from the
# BTF-off build, so `em_dev_register_perf_domain` had a wrong CRC while 8574 other
# symbols matched.
CFG_HASH=$(sha256sum out/.config | awk '{print $1}')
if [ -f out/.config-built ]; then
  if [ "$(cat out/.config-built)" != "$CFG_HASH" ]; then
    echo "ERROR: .config changed since the last build but out/ still holds stale objects."
    echo "     kbuild does not rebuild everything on a config change -> KMI CRCs mix old and new."
    echo "     Delete out and rerun:   rm -rf $K/out"
    exit 1
  fi
else
  # Skip host tool objects (out/scripts, out/tools) - only kernel objects matter.
  if find out \( -path out/scripts -o -path out/tools \) -prune -o -name '*.o' -print -quit 2>/dev/null | grep -q .; then
    echo "ERROR: out/ has kernel objects but no out/.config-built marker (build from an older script)."
    echo "     To guarantee consistent CRCs:   rm -rf $K/out"
    exit 1
  fi
  echo "$CFG_HASH" > out/.config-built
fi

# ---------- 3. ASSERT config - hard gate, never build on a mismatch ----------
echo "==> [3/8] ASSERT config"
check() { grep -qxF "$1" out/.config || { echo "  [MISSING] $1"; MISSING=1; }; }
MISSING=0
check "CONFIG_KSU=y"                                 # KSU built in
check "CONFIG_KPROBES=y"                             # KSU depends on it
check "CONFIG_EXT4_FS=y"                             # KSU depends on it
check "CONFIG_LTO_CLANG_THIN=y"                      # RAM friendly (FullLTO replaced by ThinLTO)
check "CONFIG_MODULES=y"                             # stock modules must load
check "CONFIG_MODVERSIONS=y"                         # symbol CRCs compatible with stock
check "CONFIG_PREEMPT=y"                             # stock vermagic
check "CONFIG_CFI_CLANG=y"                           # KMI/CFI compatible with stock
check "CONFIG_MODULE_UNLOAD=y"                       # stock vermagic
check "CONFIG_LOCALVERSION=\"$KREL_SUFFIX\""         # MUST MATCH the stock suffix exactly
check "# CONFIG_LOCALVERSION_AUTO is not set"        # do not let git append a suffix
check "CONFIG_DEBUG_INFO_BTF=y"                      # MANDATORY: struct module BTF fields -> KMI CRCs
check "CONFIG_DEBUG_INFO_BTF_MODULES=y"              # 2 btf_data* fields in struct module
check "CONFIG_MODULE_ALLOW_BTF_MISMATCH=y"           # allow stock modules without their own BTF
check "# CONFIG_TRIM_UNUSED_KSYMS is not set"        # the stock whitelist uses absolute paths
check "# CONFIG_MODULE_SIG_FORCE is not set"         # the unsigned susfs LKM must load
if [ "$MISSING" -ne 0 ]; then
  echo "ERROR: out/.config is missing/mismatched on the lines above - NOT building."
  echo "     Cross-check docs/PINS.md + docs/BUILD-VERIFIED.md section 5."
  exit 1
fi
echo "    [OK] 16 key lines present (KSU, ThinLTO, CFI, MODVERSIONS, BTF ON, LOCALVERSION stock)"

# Preflight: setlocalversion must return exactly the suffix, with NO '+' (see the MK comment).
SCM=$( cd out && LOCALVERSION= bash ../scripts/setlocalversion .. )
[ "$SCM" = "$KREL_SUFFIX" ] || {
  echo "ERROR: setlocalversion returned '$SCM', expected '$KREL_SUFFIX' - vermagic will be wrong."
  exit 1
}
echo "    [OK] setlocalversion: $SCM"

# ---------- 4. SMOKE: compile drivers/kernelsu on its own ----------
# security/selinux/ first, to generate flask.h which KSU needs; catch integration
# errors EARLY instead of waiting 60-120 minutes for the full build. The KSU log
# prints its version - assert 33355.
echo "==> [4/8] smoke compile security/selinux + drivers/kernelsu"
SMOKE="$STATE/smoke_ksu.log"
$MK security/selinux/ > "$SMOKE" 2>&1 || { tail -30 "$SMOKE"; echo "ERROR: security/selinux smoke failed"; exit 1; }
$MK drivers/kernelsu/ >> "$SMOKE" 2>&1 || { tail -40 "$SMOKE"; echo "ERROR: KSU smoke compile failed"; exit 1; }
grep -m1 "KernelSU-Next version: 33355" "$SMOKE" \
  || { echo "ERROR: KSU_VERSION is not 33355 - check KSU-Next clone (full history, tag v3.4.2)."; exit 1; }
grep -m1 "KernelSU-Next tag: v3.4.2" "$SMOKE" \
  || { echo "ERROR: KSU-Next tag is not v3.4.2 - wrong pin."; exit 1; }
ls out/drivers/kernelsu/*.o >/dev/null 2>&1 \
  || { echo "ERROR: no out/drivers/kernelsu/*.o after the smoke build."; exit 1; }
echo "    [OK] KSU compiles, version 33355 / tag v3.4.2"

# ---------- 5. Build Image (Image only - skip in-tree modules to save disk) ----------
echo "==> [5/8] make Image (60-120 minutes depending on the machine)"
$MK Image >> "$LOG" 2>&1 || {
  tail -50 "$LOG"
  echo "ERROR: build Image failed (full log: $LOG)"
  exit 1
}

IMG="$K/out/arch/arm64/boot/Image"
[ -s "$IMG" ] || { echo "ERROR: missing $IMG"; exit 1; }

# ---------- 6. Verify the artifact ----------
echo "==> [6/8] Verify Image"
SIZE_MB=$(( $(stat -c%s "$IMG") / 1024 / 1024 ))
echo "    Image: ${SIZE_MB} MB (stock KERNEL_SZ=$((STOCK_KERNEL_SZ / 1024 / 1024)) MB - reference)"
if [ "$SIZE_MB" -lt 20 ] || [ "$SIZE_MB" -gt 150 ]; then
  echo "ERROR: abnormal Image size - stopping, investigate before continuing."
  exit 1
fi

UTS=$(sed -n 's/^#define UTS_RELEASE "\(.*\)"/\1/p' out/include/generated/utsrelease.h)
[ "$UTS" = "$EXPECT_UTS" ] || {
  echo "ERROR: utsrelease='$UTS' != '$EXPECT_UTS' - vermagic will not match stock modules!"
  exit 1
}
echo "    [OK] utsrelease: $UTS"

# Vermagic (the part after the release) must match stock: SMP preempt mod_unload modversions aarch64
# Note: do NOT use `strings ... | grep -q` because pipefail + SIGPIPE (grep exits
# early, strings receives 141) makes the pipeline fail even when the string is there.
# Write to a file instead.
VERMAGIC_TAIL="SMP preempt mod_unload modversions aarch64"
VERMAGIC_FULL="$EXPECT_UTS $VERMAGIC_TAIL"
STRS="$STATE/strings-image.txt"
strings -a "$IMG" > "$STRS" || { echo "ERROR: strings failed on $IMG"; exit 1; }
if ! grep -qxF "$VERMAGIC_FULL" "$STRS"; then
  strings -a out/vmlinux >> "$STRS" || { echo "ERROR: strings failed on vmlinux"; exit 1; }
fi
grep -qxF "$VERMAGIC_FULL" "$STRS" \
  || { echo "ERROR: vermagic '$VERMAGIC_FULL' not found in Image/vmlinux."; exit 1; }
echo "    [OK] vermagic: $VERMAGIC_FULL"

for sym in ksu_adb_root_handle_execveat ksu_allowlist_init ksu_allow; do
  grep -q " $sym\$" out/System.map || { echo "ERROR: System.map missing KSU symbol: $sym - KSU is not in the kernel!"; exit 1; }
done
echo "    [OK] KSU symbols in System.map (ksu_adb_root_handle_execveat, ksu_allowlist_init, ksu_allow)"

# ---------- 6b. KMI GATE: symbol CRCs must match abi_gki_aarch64.xml ----------
# This is the check that decides whether the kernel can be flashed at all: stock
# vendor modules only load when every symbol CRC matches the KMI. genksyms hashes
# structs transitively, so a single wrong field in an internal struct is enough to
# break thousands of CRCs (the BTF-off bootloop lesson).
echo "==> [6b] KMI gate: comparing $(grep -c "<elf-symbol" android/abi_gki_aarch64.xml) symbols against abi_gki_aarch64.xml"
python3 "$ROOT/scripts/verify_kmi_abi.py" --kernel-src "$K" \
  || { echo "ERROR: KMI does NOT match abi_gki_aarch64.xml - do NOT flash this kernel."; exit 1; }

# ---------- 7. Save artifacts ----------
echo "==> [7/8] Save artifacts"
cp "$IMG" "$BUILD/Image-$TS"
cp out/.config "$STATE/build-$TS.config"
cp out/System.map "$STATE/System.map-$TS" 2>/dev/null || true
sha256sum "$BUILD/Image-$TS" > "$STATE/build-$TS.sha256"
echo "    build/Image-$TS"

# ---------- 8. (OPTIONAL) Package AnyKernel3 ----------
# Off by default (WITH_AK3=0): the official flash path of this kit is boot.img via
# fastboot/Skyward (writes the boot partition only). Enable with WITH_AK3=1 - which
# also requires scripts/02 to run with WITH_AK3=1 so the AnyKernel3 tree exists.
if [ "${WITH_AK3:-0}" = "1" ]; then
echo "==> [8/8] AnyKernel3 zip"
AK3="$ROOT/kernel-src/AnyKernel3"
if [ -d "$AK3" ]; then
  cp "$IMG" "$AK3/Image"
  # Configure anykernel.sh for nuwa (original osm0sis template + nuwa changes)
  sed -i "s|^kernel.string=.*|kernel.string=nuwa KernelSU-Next v3.4.2 (android13-5.15.194, ACK f4321180a397)|" "$AK3/anykernel.sh"
  sed -i 's|^device.name1=.*|device.name1=nuwa|' "$AK3/anykernel.sh"
  grep -q '^device.name1=nuwa' "$AK3/anykernel.sh" || { echo "ERROR: sed did not set device.name1 in anykernel.sh (AK3 template changed?)."; exit 1; }

  # The default AK3 template targets Galaxy Nexus: BLOCK omap, IS_SLOT_DEVICE=0, patches
  # init.tuna.rc/fstab.tuna, dump_boot+write_boot. On nuwa (GKI A/B, boot.img header v4
  # holds ONLY the kernel - the ramdisk lives in init_boot) that configuration writes
  # the wrong partition / does not work at all. Deterministic rewrite + asserts:
  #   BLOCK=boot       (do NOT use auto: auto prefers init_boot - dangerous)
  #   IS_SLOT_DEVICE=1 (A/B)
  #   split_boot       (dump+unpack boot, leaves the ramdisk alone since there is none)
  #   flash_boot       (repack with magiskboot, keep stock header/cmdline, write boot)
  python3 - "$AK3/anykernel.sh" <<'PYEOF'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = re.sub(r"^device\.name[2-5]=.*\n", "", s, flags=re.M)
s = re.sub(r"^BLOCK=.*$", "BLOCK=boot;", s, flags=re.M)
s = re.sub(r"^IS_SLOT_DEVICE=.*$", "IS_SLOT_DEVICE=1;", s, flags=re.M)
start = s.index("# boot install")
end = s.index("## end boot install")
s = s[:start] + """# boot install (nuwa: header v4, kernel-only - the ramdisk is in init_boot)
split_boot;
flash_boot;
""" + s[end:]
open(p, "w", encoding="utf-8").write(s)
PYEOF
  grep -qx 'BLOCK=boot;' "$AK3/anykernel.sh" || { echo "ERROR: anykernel.sh does not set BLOCK=boot."; exit 1; }
  grep -qx 'IS_SLOT_DEVICE=1;' "$AK3/anykernel.sh" || { echo "ERROR: anykernel.sh does not set IS_SLOT_DEVICE=1."; exit 1; }
  grep -q '^split_boot;' "$AK3/anykernel.sh" || { echo "ERROR: anykernel.sh is missing split_boot."; exit 1; }
  grep -q '^flash_boot;' "$AK3/anykernel.sh" || { echo "ERROR: anykernel.sh is missing flash_boot."; exit 1; }
  if grep -qE 'toro|toroplus|tuna|omap' "$AK3/anykernel.sh"; then
    echo "ERROR: anykernel.sh still carries Galaxy Nexus template traces (toro/tuna/omap)."; exit 1
  fi
  ( cd "$AK3" && zip -r9 -q "$BUILD/nuwa_ksun_susfs_AnyKernel3_$TS.zip" . -x '.git*' 'README*' )
  sha256sum "$BUILD/nuwa_ksun_susfs_AnyKernel3_$TS.zip" >> "$STATE/build-$TS.sha256"
  echo "    AK3 zip: build/nuwa_ksun_susfs_AnyKernel3_$TS.zip (BLOCK=boot, slot=1, split+flash)"
fi
fi

echo ""
echo "==> DONE. Artifacts:"
ls -la "$BUILD" | grep -vE "^total|^d" || true
echo "    Next: bash scripts/05_build_susfs_lkm.sh"
echo "    then: bash scripts/07_repack_boot.sh"
