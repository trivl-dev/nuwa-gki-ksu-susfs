#!/usr/bin/env bash
# 01_install_deps.sh - install the GKI kernel build packages (stock ACK set, matches CI deps)
# Requires sudo. Idempotent: safe to run again.
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "ERROR: do not run this as root/sudo directly - the script calls sudo when needed."
  exit 1
fi

echo "==> apt update + install dependencies (you will be prompted for your sudo password)"
sudo apt-get update -y
sudo apt-get install -y \
  build-essential bc bison flex \
  libncurses-dev libssl-dev libelf-dev dwarves \
  python3 python-is-python3 \
  curl git wget zip unzip cpio zstd file ccache

echo ""
echo "==> Verifying:"
for t in gcc make bc bison flex python3 git curl zip cpio; do
  command -v "$t" >/dev/null 2>&1 && echo "  [OK] $t" || { echo "  [ERROR] missing $t"; exit 1; }
done
echo "==> DONE. Next: bash scripts/02_fetch_sources.sh"
