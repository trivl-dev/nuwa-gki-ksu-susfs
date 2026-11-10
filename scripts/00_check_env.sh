#!/usr/bin/env bash
# 00_check_env.sh - check the build environment (WSL2 Ubuntu, disk space, RAM, basic tools)
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0

echo "==> Workspace: $ROOT"

# --- WSL2? ---
if grep -qi microsoft /proc/version 2>/dev/null; then
  echo "  [OK] Running inside WSL2"
else
  echo "  [WARN] WSL2 not detected. The script still runs on plain Linux,"
  echo "         but the docs/ instructions are written for Windows + WSL2."
fi

# --- Distro ---
if [ -f /etc/os-release ]; then
  . /etc/os-release
  echo "  [INFO] Distro: ${PRETTY_NAME:-unknown}"
  if [ "${ID:-}" = "ubuntu" ]; then
    case "${VERSION_ID:-}" in
      22.04|24.04|20.04) echo "  [OK] Supported Ubuntu release" ;;
      *) echo "  [WARN] Ubuntu ${VERSION_ID:-?} is untested (22.04/24.04 recommended)" ;;
    esac
  else
    echo "  [WARN] Not Ubuntu - the script still runs on modern Linux,"
    echo "         but the docs/ instructions are written for Windows + WSL2 Ubuntu 22.04/24.04."
  fi
fi

# --- Not on /mnt (drvfs) ---
case "$ROOT" in
  /mnt/*)
    echo "  [ERROR] Workspace is located on /mnt/ (Windows mount)."
    echo "         Building on drvfs is slow and can fail because of case-insensitivity."
    echo "         Copy the workspace onto the WSL ext4 filesystem, e.g. ~/nuwa-ksun-workspace"
    FAIL=1 ;;
  *) echo "  [OK] Workspace is on a native Linux filesystem" ;;
esac

# --- Disk: need >= 30 GB free ---
AVAIL_GB=$(df -BG --output=avail "$ROOT" 2>/dev/null | tail -1 | tr -dc '0-9')
if [ -n "${AVAIL_GB:-}" ]; then
  if [ "$AVAIL_GB" -ge 30 ]; then
    echo "  [OK] Free space: ${AVAIL_GB} GB (need >= 30 GB)"
  else
    echo "  [ERROR] Only ${AVAIL_GB} GB free (need >= 30 GB: source ~2GB + clang ~5GB"
    echo "         + firmware 8.2GB + extract 0.5GB + out ~3GB + headroom)"
    FAIL=1
  fi
fi

# --- RAM ---
RAM_GB=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}')
echo "  [INFO] RAM: ${RAM_GB:-?} GB - 16+ keeps LTO smooth; 8 still builds, just slower"
echo "  [INFO] CPU cores: $(nproc)"
SWAP_GB=$(free -g 2>/dev/null | awk '/^Swap:/{print $2}')
if [ "${RAM_GB:-0}" -lt 10 ] && [ "${SWAP_GB:-0}" -lt 8 ]; then
  echo "  [WARN] RAM ${RAM_GB:-?} GB + swap ${SWAP_GB:-0} GB: BTF generation (pahole) may OOM."
  echo "              BTF is REQUIRED for KMI - add swap (>= 8 GB) or use a box with >= 8 GB RAM."
fi

# --- Basic tools ---
for t in git curl tar bash; do
  if command -v "$t" >/dev/null 2>&1; then
    echo "  [OK] $t: $($t --version 2>/dev/null | head -1 | cut -c1-60)"
  else
    echo "  [ERROR] Missing '$t' - run scripts/01_install_deps.sh"
    FAIL=1
  fi
done

# pahole is REQUIRED (CONFIG_DEBUG_INFO_BTF=y preserves KMI CRCs - see docs/BUILD-VERIFIED.md section 5)
if command -v pahole >/dev/null 2>&1; then
  echo "  [OK] pahole: $(pahole --version 2>/dev/null) (required for BTF)"
else
  echo "  [ERROR] Missing pahole (package 'dwarves') - BTF is required for KMI."
  echo "         Install: sudo apt-get install -y dwarves"
  FAIL=1
fi

echo ""
if [ "$FAIL" -eq 1 ]; then
  echo "==> RESULT: FAILED - fix the [ERROR] items before running 01_install_deps.sh"
  exit 1
fi
echo "==> RESULT: PASS. Next: bash scripts/01_install_deps.sh"
