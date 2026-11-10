# SOURCE — corresponding source for released binaries

This file documents the exact source and build recipe for the kernel image and
the SUSFS module distributed in this repository's releases (GPL-2.0
compliance). It is generated from the build that was verified on device on
2026-11-10.

## Release identity

| Field | Value |
|---|---|
| Release tag | `v5.15.194-20261110` |
| `uname -r` | `5.15.194-android13-8-00019-gf4321180a397-ab15212794` |
| Kernel config | `state/stock-5.15.194.config` (in this repository), plus the deltas applied by `scripts/04_build_kernel.sh` |

## Upstream components

| Component | URL | Pin |
|---|---|---|
| Linux kernel (ACK) | <https://android.googlesource.com/kernel/common> | commit `f4321180a3973d19b626b3eef51871199e4e1fac` (branch `android13-5.15`, 5.15.194) |
| KernelSU-Next | <https://github.com/KernelSU-Next/KernelSU-Next> | tag `v3.4.2` = `4c706b5938665866ebe16944a481a7b91e3396af` |
| AOSP clang | <https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86> | `clang-r536225` (LLVM 19.0.1) |
| magiskboot | <https://github.com/topjohnwu/Magisk> | `v31.1` (used only to repack `boot.img`) |

## Modifications applied to the kernel source tree

Only these changes exist; `scripts/02_fetch_sources.sh` applies them
deterministically:

1. Symlink `drivers/kernelsu` → `KernelSU-Next/kernel`.
2. `drivers/Makefile`: add `obj-$(CONFIG_KSU) += kernelsu/`.
3. `drivers/Kconfig`: add `source "drivers/kernelsu/Kconfig"`.

No other kernel source file is modified.

## Build configuration deltas (relative to the stock config)

Applied by `scripts/04_build_kernel.sh`:

| Symbol | Value | Reason |
|---|---|---|
| `CONFIG_KSU` | `y` | KernelSU-Next built in |
| `CONFIG_LTO_CLANG_FULL` → `CONFIG_LTO_CLANG_THIN` | thin | memory/time; does not affect genksyms CRCs |
| `CONFIG_DEBUG_INFO_BTF`, `DEBUG_INFO_BTF_MODULES`, `MODULE_ALLOW_BTF_MISMATCH` | `y` | **required**: `struct module` layout participates in KMI CRCs |
| `CONFIG_TRIM_UNUSED_KSYMS` | `n` | stock whitelist path does not exist here; does not change CRCs |
| `CONFIG_UNUSED_KSYMS_WHITELIST` | `""` | same |
| `CONFIG_LOCALVERSION` | `"-android13-8-00019-gf4321180a397-ab15212794"` | must match the stock vermagic exactly |
| `CONFIG_LOCALVERSION_AUTO` | `n` | prevent `setlocalversion` suffixes |

`make` is always invoked with an empty `LOCALVERSION=` on the command line so
`scripts/setlocalversion` does not append `+` on a dirty git tree.

## Build commands

```bash
bash scripts/02_fetch_sources.sh
bash scripts/03_fetch_toolchain.sh
bash scripts/04_build_kernel.sh        # JOBS_OVERRIDE=N to force a job count
bash scripts/05_build_susfs_lkm.sh
bash scripts/06_extract_stock_boot.sh  # requires the stock fastboot package
bash scripts/07_repack_boot.sh
```

Successful output is validated by:

```bash
python3 scripts/verify_kmi_abi.py      # must report 0 mismatches
```

## Source tarball (attached to each release)

`scripts/make-source-tarball.sh` assembles
`nuwa-kernel-source-<uname -r>-<date>.tar.xz` (~150-200 MB) containing:

- the ACK tree at the pinned commit, **already wired** for KernelSU-Next
  (`drivers/kernelsu` materialised as a real directory, `drivers/Makefile` and
  `drivers/Kconfig` already patched)
- the KernelSU-Next kernel sources and its `LICENSE`
- `build-config/stock.config`, `build-config/stock-vermagic.txt`
- `scripts/`, `WIRING.md`, `MANIFEST.txt`
- `LICENSE`, `NOTICE.md`, `SOURCE.md`, `README.md`

The tarball and its `.sha256` are attached to the matching GitHub release, so
the corresponding source is available even for users who cannot reach
`android.googlesource.com`.

Regenerate it for every release:

```bash
bash scripts/make-source-tarball.sh <tag-date>
```

## Published artifacts and hashes

| Artifact | Size | SHA-256 |
|---|---|---|
| `Image-20261110` | 40,937,984 B | `cc8425a045beba8139839fd42371d3f3bea0c460d1c4369320a2d2b83f061e8e` |
| `nuwa-ksun-susfs_boot_20261110.img` | 100,663,296 B | `0b7d4687814c8818b563b7df7e90148eb5fc0eceb2f8fbb03237e66018b40d00` |
| `susfs_guard_lkm.ko` | 4,447,560 B | `8d8976cf996f850f7128bb25c3f060a163b4bcd0fb4da751f89872c8a799e0fe` |

Releases also publish `SHA256SUMS` and (optionally) `System.map`.

## Note on vendor modules

`vendor_boot` / `vendor_dlkm` modules are **not** part of this project and are
not redistributed. They are covered by the device vendor's terms; the kernel
here is built to remain binary-compatible with them (see
`docs/BUILD-VERIFIED.md` §5).
