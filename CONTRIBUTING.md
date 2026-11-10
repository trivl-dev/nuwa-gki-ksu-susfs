# Contributing

Thanks for taking the time to help. This project builds a **GKI kernel for the
Xiaomi 13 Pro (nuwa)** that must stay binary-compatible with the stock vendor
modules. That constraint drives most of the rules below.

## Scope

In scope:

- build, packaging and verification tooling;
- documentation fixes and translations of existing docs;
- support for a newer HyperOS release **that keeps the same kernel ABI**
  (see `docs/PINS.md`, re-pin rules);
- bug fixes that keep the KMI intact.

Out of scope (open an issue before writing code):

- switching to a vendor OSS tree, a ROM tree or another kernel base;
- disabling `CONFIG_DEBUG_INFO_BTF` or any other ABI-affecting config;
- kernel feature additions (schedulers, overclocking, extra filesystems, ...);
- flashing anything other than the `boot` partition.

## Reporting a bug

Please include:

1. `adb shell uname -r` and `adb shell getprop ro.build.display.id`.
2. KernelSU-Next manager version (for example `v3.4.2 (33355-5)`).
3. Which artifact you flashed (file name + SHA-256 if you still have it).
4. Reproduction steps.
5. With root available:

   ```bash
   adb shell "su -c 'dmesg | grep -iE \"disagrees about version|Unknown symbol\"'"
   adb shell "su -c 'cat /proc/version'"
   ```

   The first command must be empty. If it is not, the kernel does not match the
   firmware ABI — that is the most important clue you can give us.

State clearly whether you restored the stock `boot.img` afterwards.

## Before sending a pull request

```bash
bash scripts/00_check_env.sh          # environment is sane
bash -n scripts/*.sh                  # shell syntax
python3 -m py_compile scripts/*.py    # python syntax
python3 scripts/verify_kmi_abi.py     # must report 0 mismatches
```

Rules for changes that touch the build:

- Any `.config` change **requires a clean build**:
  `rm -rf kernel-src/sm8550/out`. The build script enforces this with
  `out/.config-built`; do not bypass it.
- Never disable `CONFIG_DEBUG_INFO_BTF` or `DEBUG_INFO_BTF_MODULES`. They change
  `struct module` and therefore most KMI CRCs.
- Keep `CONFIG_LOCALVERSION` identical to the stock suffix and
  `LOCALVERSION_AUTO=n`; `make` must always be invoked with an empty
  `LOCALVERSION=` on the command line.
- Do not add `|| true` around patch, configuration or build steps. If a step
  fails, the build must stop.

## Commit messages

Conventional Commits, one logical change per commit:

```
feat(build): add KMI gate for the SUSFS module
fix(boot): keep the stock cmdline when repacking
docs: clarify OTA rollback steps
ci: cache the clang toolchain
chore: drop unused helper
```

Allowed scopes include `build`, `boot`, `kmi`, `scripts`, `ci`, `release`,
`state`, `readme`. Write the body in the imperative mood and explain **why**,
not only what.

## Coding style

- Shell: POSIX-friendly bash, `set -euo pipefail`, quoted expansions,
  `shellcheck` clean where practical. Keep user-facing strings ASCII.
- Python: standard library only, `python3` (no third-party packages).
- Never commit build output, firmware, vendor modules or downloaded toolchains;
  see `.gitignore`.
- Do not add binary blobs of unknown origin.

## License

By contributing you agree that your changes are licensed under **GPL-2.0**, the
license of the kernel. If you copy code from another project, state its origin
and license in `NOTICE.md`.
