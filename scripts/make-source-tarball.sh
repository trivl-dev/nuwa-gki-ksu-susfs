#!/usr/bin/env bash
# make-source-tarball.sh - assemble the corresponding-source tarball for a release.
#
# The tarball contains everything needed to rebuild the released kernel:
#   1. the ACK kernel tree at the pinned commit, already wired for KernelSU-Next
#   2. the KernelSU-Next kernel sources (materialised at drivers/kernelsu)
#   3. the stock build config + the build scripts
#   4. licensing/attribution files
#
# Usage:  bash scripts/make-source-tarball.sh [tag-date]
# Output: build/nuwa-kernel-source-<uname -r>-<date>.tar.xz
#
# Requires kernel-src/sm8550 and kernel-src/KernelSU-Next to be present
# (run scripts/02_fetch_sources.sh first). Uses `git archive`, so untracked
# build output (out/) is never included.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K="$ROOT/kernel-src/sm8550"
KSU="$ROOT/kernel-src/KernelSU-Next"
BUILD="$ROOT/build"
STATE="$ROOT/state"
TS="${1:-$(date +%Y%m%d)}"

[ -d "$K/.git" ]   || { echo "ERROR: kernel tree missing - run scripts/02_fetch_sources.sh"; exit 1; }
[ -d "$KSU/.git" ] || { echo "ERROR: KernelSU-Next missing - run scripts/02_fetch_sources.sh"; exit 1; }
[ -s "$STATE/stock-5.15.194.config" ] || { echo "ERROR: missing state/stock-5.15.194.config"; exit 1; }

KREL=$(sed -n 's/^#define UTS_RELEASE "\(.*\)"/\1/p' "$K/out/include/generated/utsrelease.h" 2>/dev/null || true)
if [ -z "$KREL" ]; then
  KREL=$(awk '{print $1}' "$STATE/stock-vermagic.txt" 2>/dev/null || true)
fi
[ -n "$KREL" ] || { echo "ERROR: cannot determine the kernel release string"; exit 1; }

NAME="nuwa-kernel-source-$KREL-$TS"
OUT="$BUILD/$NAME.tar.xz"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
PKG="$STAGE/$NAME"
mkdir -p "$PKG"

echo "==> Kernel release: $KREL"
echo "==> Staging in $PKG"

# 1. Kernel tree at the pinned commit (tracked files only, no .git, no out/)
git -C "$K" archive --format=tar HEAD | tar -x -C "$PKG"
mkdir -p "$PKG/linux"
# git archive extracted into $PKG; move the tree under linux/ for a tidy layout
for entry in "$PKG"/*; do
  base=$(basename "$entry")
  [ "$base" = "linux" ] && continue
  mv "$entry" "$PKG/linux/"
done

# 2. KernelSU-Next sources, materialised where the symlink would point
KSU_SHA=$(git -C "$KSU" rev-parse HEAD)
mkdir -p "$PKG/linux/drivers/kernelsu" "$STAGE/ksu-tmp"
git -C "$KSU" archive --format=tar HEAD kernel | tar -x -C "$STAGE/ksu-tmp"
cp -a "$STAGE/ksu-tmp/kernel/." "$PKG/linux/drivers/kernelsu/"
cp -a "$KSU/LICENSE" "$PKG/KernelSU-Next-LICENSE"

# 3. Wiring: reproduce the two edits applied by scripts/02_fetch_sources.sh
KMAKE="$PKG/linux/drivers/Makefile"
KKCONF="$PKG/linux/drivers/Kconfig"
# Mirror scripts/02_fetch_sources.sh exactly: append the obj line once, and
# insert the Kconfig source line right before endmenu.
if ! grep -q '^obj-\$(CONFIG_KSU) += kernelsu/' "$KMAKE"; then
  printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$KMAKE"
fi
grep -q '^obj-\$(CONFIG_KSU) += kernelsu/' "$KMAKE" \
  || { echo "ERROR: KSU Makefile wiring missing"; exit 1; }
[ "$(grep -c '^obj-\$(CONFIG_KSU) += kernelsu/$' "$KMAKE")" = "1" ] \
  || { echo "ERROR: KSU Makefile wiring duplicated"; exit 1; }

if ! grep -q '^source "drivers/kernelsu/Kconfig"' "$KKCONF"; then
  sed -i '0,/^endmenu/s|^endmenu|source "drivers/kernelsu/Kconfig"\nendmenu|' "$KKCONF"
fi
grep -q '^source "drivers/kernelsu/Kconfig"' "$KKCONF" \
  || { echo "ERROR: KSU Kconfig wiring missing"; exit 1; }
[ "$(grep -c '^source "drivers/kernelsu/Kconfig"$' "$KKCONF")" = "1" ] \
  || { echo "ERROR: KSU Kconfig wiring duplicated"; exit 1; }
[ -f "$PKG/linux/drivers/kernelsu/Kconfig" ] \
  || { echo "ERROR: drivers/kernelsu/Kconfig missing"; exit 1; }

# 4. Build config, scripts and licensing
mkdir -p "$PKG/build-config"
cp "$STATE/stock-5.15.194.config" "$PKG/build-config/stock.config"
cp "$STATE/stock-vermagic.txt" "$PKG/build-config/stock-vermagic.txt"
SCRIPTS_DIR="${SCRIPTS_DIR:-$ROOT/scripts}"
DOCS_DIR="${DOCS_DIR:-$ROOT}"
cp -a "$SCRIPTS_DIR" "$PKG/scripts"
for f in LICENSE NOTICE.md SOURCE.md README.md; do
  [ -f "$DOCS_DIR/$f" ] && cp "$DOCS_DIR/$f" "$PKG/"
done

cat > "$PKG/WIRING.md" <<EOF
# KernelSU-Next wiring

This source tree already contains the three changes that
\`scripts/02_fetch_sources.sh\` applies to a pristine ACK checkout:

1. \`linux/drivers/kernelsu/\` - KernelSU-Next kernel sources, copied here
   (normally a symlink to \`../../KernelSU-Next/kernel\`).
2. \`linux/drivers/Makefile\` - \`obj-\$(CONFIG_KSU) += kernelsu/\` (appended, as
   the build system expects it after the other obj entries).
3. \`linux/drivers/Kconfig\` - \`source "drivers/kernelsu/Kconfig"\` (before
   \`endmenu\`).

Kernel tree:      $(git -C "$K" rev-parse HEAD)
KernelSU-Next:    $KSU_SHA
Kernel release:   $KREL

Build:
    cp build-config/stock.config linux/.config     # then apply the deltas
    # see scripts/04_build_kernel.sh for the exact deltas and flags
EOF

# 5. Manifest + checksums
{
  echo "kernel   $(git -C "$K" rev-parse HEAD)"
  echo "ksun     $KSU_SHA"
  echo "release  $KREL"
  echo "built    $TS"
} > "$PKG/MANIFEST.txt"

echo "==> Creating $OUT (this takes a few minutes)"
tar -C "$STAGE" -cf - "$NAME" | xz -T4 -6 > "$OUT"
sha256sum "$OUT" | tee "$OUT.sha256"

echo ""
echo "==> DONE"
ls -lh "$OUT"
echo "Attach both files to the GitHub release next to the kernel image."
