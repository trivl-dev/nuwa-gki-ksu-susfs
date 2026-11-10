#!/usr/bin/env bash
# 03_fetch_toolchain.sh - download AOSP clang-r536225 + extract magiskboot (x86_64) from Magisk APK.
# Idempotent: skips anything already downloaded correctly. Total download ~2 GB.
# Pin and rationale: docs/PINS.md section A + "Toolchain notes" (verified live 2026-11-08).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="$ROOT/tools"
STATE="$ROOT/state"
mkdir -p "$TOOLS" "$STATE"

CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/clang-r536225.tar.gz"
MAGISK_VER="v31.1"
MAGISK_APK_URL="https://github.com/topjohnwu/Magisk/releases/download/${MAGISK_VER}/Magisk-${MAGISK_VER}.apk"

# ---------- 1. Clang r536225 ----------
if [ -x "$TOOLS/clang/bin/clang" ]; then
  echo "==> [SKIP] clang already present: $TOOLS/clang"
else
  echo "==> Downloading clang-r536225 (~2 GB, a few minutes)..."
  mkdir -p "$TOOLS/clang"
  # googlesource +archive tarballs unpack DIRECTLY into the target (no subdirectory)
  curl -fL "$CLANG_URL" | tar -xz -C "$TOOLS/clang"
fi
export PATH="$TOOLS/clang/bin:$PATH"
clang --version | head -1 | tee "$STATE/clang.version"
# r536225 = "based on r536225" clang 19.0.1 (the Android prebuilt that community CI
# uses for sm8550/5.15 - verified in practice 2026-11-08; AOSP refreshed the build in-revision)
clang --version | grep -q "clang version 19" \
  || { echo "ERROR: downloaded clang is not the expected r536225/clang-19 - odd tarball."; exit 1; }
echo "    [OK] clang-r536225 (LLVM 19.0.1, Android prebuilt)"

# ---------- 2. magiskboot (x86_64) from the Magisk APK ----------
MB="$TOOLS/magiskboot"
mkdir -p "$MB"
if [ -x "$MB/magiskboot" ]; then
  echo "==> [SKIP] magiskboot already present: $MB/magiskboot"
else
  echo "==> Downloading Magisk ${MAGISK_VER} APK (~12 MB) and extracting x86_64 magiskboot..."
  curl -fL -o "$MB/Magisk.apk" "$MAGISK_APK_URL"
  # unzip is required (script 01 installs it; if absent, fall back to python3 zipfile)
  if command -v unzip >/dev/null 2>&1; then
    unzip -o -j "$MB/Magisk.apk" 'lib/x86_64/libmagiskboot.so' -d "$MB" >/dev/null
  else
    python3 - "$MB/Magisk.apk" "$MB/libmagiskboot.so" <<'PYEOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    with open(sys.argv[2], "wb") as f:
        f.write(z.read("lib/x86_64/libmagiskboot.so"))
PYEOF
  fi
  mv "$MB/libmagiskboot.so" "$MB/magiskboot"
  chmod 755 "$MB/magiskboot"
  rm -f "$MB/Magisk.apk"
fi

# Assert: magiskboot runs on this machine (usage text contains "unpack")
USAGE=$("$MB/magiskboot" 2>&1 || true)
echo "$USAGE" | grep -q "unpack" \
  || { echo "ERROR: the x86_64 magiskboot does not run on this machine."; echo "$USAGE" | head -5; exit 1; }
echo "    [OK] magiskboot x86_64 runs"

echo "$MAGISK_VER" > "$STATE/magiskboot.version"
echo ""
echo "==> DONE. Next: bash scripts/04_build_kernel.sh"
