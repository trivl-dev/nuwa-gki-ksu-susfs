# BUILD-VERIFIED — verified facts, KMI rules and post-mortem

Reference document for this project. Everything below was verified on real
hardware or against Google's own ABI data; assumptions are marked **UNVERIFIED**
where applicable.

Target: Xiaomi 13 Pro (`nuwa`, SM8550), HyperOS 3 Global
`OS3.0.303.0.WMBMIXM` (Android 16), bootloader unlocked.

---

## 1. What the stock kernel actually is

The stock `boot.img` contains a raw ARM64 `Image` whose version string is:

```
5.15.194-android13-8-00019-gf4321180a397-ab15212794
SMP preempt mod_unload modversions aarch64
```

That string encodes the source: ACK branch `android13-5.15`, sublevel 194, git
description `g00019` (19 commits after `v5.15.194`), commit `f4321180a397`, and
the Android build id `ab15212794`.

The config embedded in the same image (`IKCONFIG`) confirms it: `GKI_HIDDEN_*`
symbols, `ARCH_QCOM=y`, and build paths under
`/mnt/disks/.../common-android13-5.15-...`. `scripts/06_extract_stock_boot.sh`
extracts both the config and the exact vermagic into `state/`.

**Consequence:** any replacement kernel must reproduce this ABI. A vendor OSS
tree (Xiaomi's `fuxi-t-oss`, 5.15.41) or a ROM tree (5.15.22x) does not, and
breaks stock module loading.

---

## 2. Why vermagic is not enough

With `CONFIG_MODVERSIONS=y`, the kernel compares module version data in
`check_version()` and `same_magic()`. Two things matter:

1. **The vermagic tail** — after the first space: `SMP preempt mod_unload
   modversions aarch64`. The version prefix is *ignored* when the module
   carries CRCs. This is why the 328 stock vendor modules, which report
   `vermagic=5.15.78`, still load on a 5.15.194 kernel.
2. **Per-symbol CRCs** — each module lists a CRC for every imported symbol in
   its `__versions` section. A single mismatch produces
   `disagrees about version of symbol <name>` and the module is rejected.

This project therefore keeps the exact stock vermagic *and* proves CRC parity
on every build.

---

## 3. CRC compatibility rules (the expensive lesson)

genksyms computes a CRC per exported symbol from the declaration in the
preprocessed source, expanding every referenced struct **transitively**. One
field difference anywhere in the type graph changes the CRC of every symbol
that reaches it.

The critical case is `struct module`:

```c
/* include/linux/module.h */
#ifdef CONFIG_DEBUG_INFO_BTF_MODULES
	unsigned int btf_data_size;
	void *btf_data;
#endif
```

`struct module` is reachable from a huge part of the KMI type graph
(`sk_buff → net_device → device → device_driver → module`, `inode →
super_block → … → module`, …). Disabling `DEBUG_INFO_BTF` therefore changes
the CRC of `module_layout` **and about 63% of all exported symbols**:

| Build | `module_layout` CRC | KMI symbols matching Google ABI |
|---|---|---|
| BTF disabled | `0x4ccd63ed` | 3,375 / 8,585 |
| BTF enabled | `0x0222dd63` | **8,575 / 8,585 (0 mismatch)** |

Rules that follow from this:

- `CONFIG_DEBUG_INFO_BTF=y` and `CONFIG_DEBUG_INFO_BTF_MODULES=y` are
  **mandatory**. Never disable them to work around a `pahole` OOM — free RAM,
  add swap, or run the link step with `-j1` instead.
- Any `.config` change requires a **clean build** (`rm -rf kernel-src/sm8550/out`).
  kbuild only tracks the `include/config/<SYMBOL>` files each object depends
  on, so a config change can leave stale objects behind, and those objects keep
  their old genksyms CRCs. `scripts/04_build_kernel.sh` stores a config hash in
  `out/.config-built` and refuses to continue if the config changed while
  objects still exist.
- Verify with Google's own ABI data, not with intuition:
  `python3 scripts/verify_kmi_abi.py`.

---

## 4. Build configuration

`scripts/04_build_kernel.sh` starts from `state/stock-5.15.194.config` and
applies these deltas:

| Symbol | Value | Why |
|---|---|---|
| `CONFIG_KSU` | `y` | KernelSU-Next built in |
| `LTO_CLANG_FULL` → `LTO_CLANG_THIN` | thin | memory/time; genksyms CRCs are unaffected |
| `DEBUG_INFO_BTF`, `DEBUG_INFO_BTF_MODULES`, `MODULE_ALLOW_BTF_MISMATCH` | `y` | required for KMI (section 3) |
| `TRIM_UNUSED_KSYMS` | `n` | stock whitelist points to a Google build path |
| `UNUSED_KSYMS_WHITELIST` | `""` | same |
| `LOCALVERSION` | `-android13-8-00019-gf4321180a397-ab15212794` | must equal the stock suffix |
| `LOCALVERSION_AUTO` | `n` | prevents automatic suffixes |

`make` is always called with an **empty** `LOCALVERSION=` on the command line.
Without it, `scripts/setlocalversion` appends `+` on a dirty tree (the KSU
wiring makes the tree dirty), producing `…-ab15212794+` and a wrong vermagic.

The script asserts 16 config lines, checks `setlocalversion` output, smoke
compiles `security/selinux/` and `drivers/kernelsu/` (asserting
`KernelSU-Next version: 33355` and `tag: v3.4.2`), then builds `Image` only
(no in-tree modules).

---

## 5. Boot image and flash model

`boot.img` uses header **v4** and contains only the raw kernel `Image`:
`RAMDISK_SZ=0`, no DTB (they live in `init_boot` and `vendor_boot`
respectively). Replacing the kernel therefore means writing **only the `boot`
partition**.

- Primary path: `scripts/07_repack_boot.sh` — magiskboot unpacks the stock
  `boot.img`, swaps the `kernel` file, repacks with the original header,
  cmdline and page size, then verifies the round trip byte-for-byte.
- Optional path: AnyKernel3 zip (`WITH_AK3=1`). Not needed for the boot.img
  flow and disabled by default.
- Flashing a custom kernel changes the AVB hash inside `vbmeta`, so the device
  shows an orange/red state warning on boot. That is expected. Never flash a
  disable-verification `vbmeta` and never re-lock the bootloader.

Detailed procedure and rollback: `docs/FLASH-SAFETY.md`.

---

## 6. Verification record (2026-11-10)

| Check | Result |
|---|---|
| Config asserts | 16/16 |
| `setlocalversion` | `-android13-8-00019-gf4321180a397-ab15212794` (no `+`) |
| KSU smoke | version 33355, tag v3.4.2 |
| `Image` | 40,937,984 bytes, `Linux kernel ARM64 boot executable Image, little-endian, 4K pages` |
| `uname -r` / vermagic | exact stock string |
| KSU symbols | `ksu_adb_root_handle_execveat`, `ksu_allowlist_init`, `ksu_allow` in `System.map` |
| BTF in image | present (2,399,940 B types + 1,470,820 B strings) |
| **KMI vs `android/abi_gki_aarch64.xml`** | **8,575 match, 0 mismatch**, `module_layout = 0x0222dd63` |
| **328 stock modules from `vendor_boot`** | **15,092 CRC entries, 0 mismatch** |
| `susfs_guard_lkm.ko` | vermagic matches; 6 symbols intentionally undefined (resolved by ksud) |
| `boot.img` round trip | kernel inside repacked image is byte-identical to `Image` |
| On device | boots, manager reports 33355 / v3.4.2 / Working, SUSFS LKM loads |

Artifact hashes are recorded in `SOURCE.md`.

---

## 7. Post-mortem — every failure hit while getting here

1. **Boot loop with a 5.15.41 vendor kernel.** The first attempt used Xiaomi's
   OSS tree (`fuxi-t-oss`, 5.15.41) with a vendor config fragment. The device
   looped. Root cause was not the version prefix (section 2) but CRC mismatch:
   a different source tree and config produce different struct layouts.
2. **Boot loop with the correct commit but BTF disabled.** After re-pinning to
   ACK 5.15.194 and extracting the stock config, the build still mismatched
   5,210 of 8,585 CRCs. Diffing the stock kernel's embedded BTF against the
   build's DWARF showed the only structural difference was `struct module`
   (missing `btf_data_size` / `btf_data`). Enabling BTF restored every CRC.
3. **Stale objects after a config change.** With BTF re-enabled, one symbol
   (`em_dev_register_perf_domain`) still mismatched: 326 objects were left over
   from the BTF-off build because kbuild does not rebuild everything on a
   config change. Running genksyms by hand on the current source produced the
   correct CRC. Fixed by wiping `out/`; now guarded by `out/.config-built`.
4. **`pahole` OOM during BTF generation.** With 3.9 GB RAM the BTF step was
   killed, leaving an empty `.BTF` section and `resolve_btfids` failing with
   "Invalid argument". With 7.7 GB RAM + 8 GB swap and `-j6` it completes. If it
   happens to you: add swap or run the link step with `-j1`. Do **not** disable
   BTF.
5. **`pipefail` + `grep -q` false failures.** `strings image | grep -qxF value`
   reports failure when `grep` exits early, because `strings` gets SIGPIPE
   (exit 141) and `pipefail` propagates it. All such checks now write to a file
   first.
6. **`No rule to make target 'scripts/module.lds'`** when building the external
   SUSFS module after `make Image` only. `scripts/05_build_susfs_lkm.sh` runs
   `modules_prepare` when the file is missing.
7. **`Module.symvers` is not produced by `make Image`.** Only
   `vmlinux.symvers` is. Script 05 copies it before building the external
   module. Note that a stale `Module.symvers` can also make verification read
   old CRCs — `verify_kmi_abi.py` prefers `vmlinux.symvers` for that reason.
8. **`modpost` reports 6 undefined symbols for the SUSFS module.** By design:
   `task_work_add`, `init_mm`, `saved_boot_config`, `dcache_clean_inval_poc`,
   `copy_to_kernel_nofault`, `__set_fixmap` are resolved by the ksud loader via
   kallsyms. The build uses `KBUILD_MODPOST_WARN=1` for this module only.
9. **AnyKernel3 template is a Galaxy Nexus one** (`BLOCK=/dev/block/platform/omap/…`,
   `IS_SLOT_DEVICE=0`, patches `init.tuna.rc`). If you enable `WITH_AK3=1`, the
   script rewrites it to `BLOCK=boot`, `IS_SLOT_DEVICE=1`,
   `split_boot; flash_boot;` and asserts no template leftovers remain.

---

## 8. Reproducing / troubleshooting

```bash
rm -rf kernel-src/sm8550/out      # mandatory after any .config change
bash scripts/04_build_kernel.sh   # JOBS_OVERRIDE=6 to force parallelism
bash scripts/05_build_susfs_lkm.sh
bash scripts/06_extract_stock_boot.sh
bash scripts/07_repack_boot.sh
```

If something fails:

- `state/build.log` — full kbuild log.
- `state/04_build_kernel.log` — step-by-step progress and assertions.
- `state/build-<date>.sha256` — hashes of produced artifacts.
- `python3 scripts/verify_kmi_abi.py --json` — machine-readable KMI report.
- `scripts/btf_dump.py` / `scripts/btf_diff.py` — compare struct layouts
  between a stock kernel image (embedded BTF) and a local build. Useful when a
  CRC mismatch appears after a config change.

---

## 9. Known limitations

- BTF is generated for `vmlinux`; the optional in-tree module BTF is not built
  here because only `Image` is produced. Stock modules carry their own BTF or
  none, and `MODULE_ALLOW_BTF_MISMATCH=y` keeps them loadable.
- `resolve_btfids` may print warnings about a few unexported/inlined functions
  (for example `dentry_open`). They do not affect the KMI or runtime behaviour.
- The KMI gate validates exported symbol CRCs; it does not validate internal
  `struct` layouts used only inside the kernel. Those are covered by the
  matching config and source pin.
- `vendor_dlkm` modules live inside `super.img` and are not part of the offline
  check; the 328 modules from `vendor_boot` cover the same KMI and all match.
- Re-locking the bootloader with a custom kernel is unsupported and can brick
  the device (EDL recovery only).
