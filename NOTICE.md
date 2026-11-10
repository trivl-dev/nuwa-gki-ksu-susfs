# NOTICE

This project builds and redistributes a Linux kernel binary. The components
involved and their licenses are listed below.

| Component | License | How it is used here |
|---|---|---|
| Linux kernel (Android Common Kernel, `android13-5.15`) | **GPL-2.0** (with Linux syscall note) | Base source of the kernel image. Full text: `LICENSE`. |
| KernelSU-Next (`KernelSU-Next/KernelSU-Next`, tag `v3.4.2`) | **GPL-3.0** | Built into the kernel image via `drivers/kernelsu`. Source: <https://github.com/KernelSU-Next/KernelSU-Next> |
| AnyKernel3 (`osm0sis/AnyKernel3`) | BSD-3-Clause-style (see upstream `LICENSE`) | **Optional**, disabled by default (`WITH_AK3=0`). Not part of the default output. |
| AOSP LLVM/clang prebuilts (`clang-r536225`) | Apache-2.0 with LLVM exceptions | Build toolchain only, downloaded by `scripts/03_fetch_toolchain.sh`, not redistributed. |
| Magisk (`topjohnwu/Magisk`, `v31.1` APK) | GPL-3.0 | Only `lib/x86_64/libmagiskboot.so` is extracted at build time to unpack/repack `boot.img`. Not redistributed. |
| Xiaomi stock firmware and vendor modules | Proprietary | **Not distributed** by this repository. Users must obtain their own stock fastboot package. |

## Notes on redistribution

- If you publish a kernel image built with these scripts, you must also make the
  corresponding source available (GPL-2.0). `SOURCE.md` documents the exact
  recipe; keep it accurate for every release you publish.
- Keep this file and `LICENSE` in any redistribution.
- Do not redistribute Xiaomi firmware images, `boot.img` dumps, or the
  proprietary vendor modules (`*.ko` from `vendor_dlkm` / `vendor_boot`).
  They are not covered by any license granted to this project.
