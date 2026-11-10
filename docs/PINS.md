# PINS — versions and re-pin policy

All pins below were verified live on **2026-11-10** (`git ls-remote` / HTTP
HEAD). The scripts embed these values and **assert** them after cloning: if an
upstream moves, the script fetches the pinned object; if the pinned object
disappears (force-push / deletion), the script stops with an error instead of
silently building something else.

## A. Build sources

| Component | URL | Pin | Notes |
|---|---|---|---|
| Kernel | `https://android.googlesource.com/kernel/common` | commit `f4321180a3973d19b626b3eef51871199e4e1fac` (ACK `android13-5.15`, **5.15.194**) | The exact commit the stock kernel was built from — the stock version string embeds this hash. Fetched shallow by SHA. |
| Build config | `state/stock-5.15.194.config` | SHA-256 `eb03e6badcccd7841043517a26838ad41473d041c09a72020690648deaf5064b` | Extracted from the stock `boot.img` (`IKCONFIG`). This is the single source of truth for the ABI; do not substitute a generic defconfig. |
| KernelSU-Next | `https://github.com/KernelSU-Next/KernelSU-Next.git` | tag `v3.4.2` = `4c706b5938665866ebe16944a481a7b91e3396af` | **KSU_VERSION 33355.** Must be cloned with **full history**: `KSU_VERSION = 30000 + git rev-list --count HEAD`; a shallow clone yields the wrong version and the manager will not recognise the kernel. `scripts/02_fetch_sources.sh` asserts `rev-list --count HEAD` = 3355. |
| Toolchain | `https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/clang-r536225.tar.gz` | `clang-r536225` (LLVM 19.0.1) | ~1.1 GB download, ~3.6 GB unpacked. Script 03 asserts the reported version. |
| magiskboot | `https://github.com/topjohnwu/Magisk/releases/download/v31.1/Magisk-v31.1.apk` | Magisk `v31.1` | Only `lib/x86_64/libmagiskboot.so` is used (unpack/repack `boot.img`), extracted by script 03. |
| AnyKernel3 (optional) | `https://github.com/osm0sis/AnyKernel3.git` | `master` = `41f04bdb4ee30a44e429c2c1131d5e8bb32b15f1` | Only fetched when `WITH_AK3=1`. Not needed for the `boot.img` flash flow. |
| ABI corpus snapshot | `state/kmi/abi_gki_aarch64.xml.xz` | SHA-256 `bd8e32895312be0b198d797f88b2294e06bca7eb326a49cc753da44e8636d436` | Compressed copy of `android/abi_gki_aarch64.xml` from the pinned commit. Lets `scripts/verify_kmi_abi.py` validate a released image without the 1.4 GB kernel tree. |
| Recorded KMI symbol table | `state/kmi/vmlinux.symvers-20261110` | from the verified build | Used with `--symvers` to re-check a released image offline. |

## B. Firmware

The stock fastboot package is **not** distributed with this repository.

| Item | Value |
|---|---|
| Package | `nuwa_global_images_OS3.0.303.0.WMBMIXM_20260920.0000.00_16.0_global_d358f7a446.tgz` |
| MD5 | `d358f7a44683f5a74bf84842cf468ba1` |

Place it in `firmware/` before running `scripts/06_extract_stock_boot.sh`.
The script verifies the MD5 and extracts only `boot.img`, `init_boot.img`,
`vendor_boot.img`, `dtbo.img`, `vbmeta.img` and `recovery.img` (~250 MB).

For a different (newer) HyperOS build use `MD5_OVERRIDE=1`, but only after
confirming the file is genuine; then follow the re-pin rules in section D.

## C. Required host tools

`build-essential bc bison flex libncurses-dev libssl-dev libelf-dev dwarves
python3 python-is-python3 curl git wget zip unzip cpio zstd file ccache`

`dwarves` (pahole) is **mandatory**: `CONFIG_DEBUG_INFO_BTF` must stay enabled
for KMI compatibility (see `docs/BUILD-VERIFIED.md` §4).

## Toolchain notes

- The stock kernel was built with **clang 14.0.7 (r450784e)**; this project
  builds with **clang 19.0.1 (r536225)**. This was proven not to affect KMI:
  genksyms derives symbol CRCs from the preprocessed source, and after the BTF
  config fix every checked symbol (`module_layout`, `skb_put`, `__alloc_skb`,
  `kfree_skb`, ...) matches `android/abi_gki_aarch64.xml` exactly. The real
  requirement is the **config** (struct layouts), not the compiler version.
- `HOSTCC=gcc` is intentional: host tools are built with the system GCC. Some
  clang bundles ship an `ld` too old for newer glibc `.relr.dyn` sections.
- Known issue when building 5.15 with clang ≥16: `-Werror=enum-constexpr-conversion`
  in a few files. If it appears, add
  `KCFLAGS="-Wno-enum-constexpr-conversion"` to the `make` invocation
  (no effect on ABI or vermagic).

## D. Re-pin rules

1. Re-pin only for a clear reason: a Xiaomi OTA that bumps the kernel
   sublevel, an ASB bump that changes the ABI, or an upstream deletion of the
   pinned object. Read the commits between the old and new pin before deciding.
2. After a re-pin, run the full pipeline (`02` → `07`) and prove KMI
   compatibility with `python3 scripts/verify_kmi_abi.py` before flashing
   anything.
3. **Do not** switch to a different kernel base (vendor OSS tree, ROM tree,
   community kernel). Those carry a different vermagic/KMI and break stock
   module loading.
4. **Do not** switch KernelSU-Next to a dev branch. Only stable release tags.
5. **Do not** disable `CONFIG_DEBUG_INFO_BTF`. It changes `struct module` and
   therefore the CRC of most KMI symbols.
6. When Xiaomi bumps the sublevel (e.g. 5.15.194 → 5.15.20x): run
   `scripts/06_extract_stock_boot.sh` to obtain the new
   `state/stock-<ver>.config` and `state/stock-vermagic.txt`, find the matching
   ACK commit (the hash is embedded in the stock version string), re-pin
   `KERNEL_SHA` / `KERNEL_VER` / `KREL_SUFFIX` in scripts 02 and 04, then
   **wipe `kernel-src/sm8550/out` and rebuild from scratch**.

### Re-verifying the pins

```bash
git ls-remote https://android.googlesource.com/kernel/common f4321180a3973d19b626b3eef51871199e4e1fac
git ls-remote https://github.com/KernelSU-Next/KernelSU-Next.git refs/tags/v3.4.2
curl -sIL -o /dev/null -w "%{http_code}\n" \
  "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/clang-r536225.tar.gz"
```
