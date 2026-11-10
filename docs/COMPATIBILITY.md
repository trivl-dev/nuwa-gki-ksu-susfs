# Compatibility

This project is built for **one device and one firmware family**. Anything else
is untested and may brick or boot-loop.

## Supported combination

| | |
|---|---|
| Device | Xiaomi 13 Pro (`nuwa`, model `2210132G`, SM8550) |
| Firmware | HyperOS 3 Global `OS3.0.303.0.WMBMIXM` |
| Android | 16 (SDK 36) |
| Kernel | `5.15.194-android13-8-00019-gf4321180a397-ab15212794` |
| KernelSU-Next (kernel) | v3.4.2 (KSU_VERSION 33355) |
| KernelSU-Next (manager) | v3.4.2 (33355-5) |
| SUSFS | v2.3.0 (GKI), loaded by ksud |

## Releases

| Release | Firmware | Kernel | KernelSU-Next | SUSFS | Status |
|---|---|---|---|---|---|
| [v5.15.194-20261110](https://github.com/trivl-dev/nuwa-gki-ksu-susfs/releases/tag/v5.15.194-20261110) | `OS3.0.303.0.WMBMIXM` | `5.15.194-android13-8-00019-gf4321180a397-ab15212794` | v3.4.2 (33355) | v2.3.0 | ✅ verified on device |

New rows are added for every release. Old releases stay available for users who
have not updated their firmware yet.

## Check what you are running

```bash
adb shell getprop ro.product.device           # must be: nuwa
adb shell getprop ro.build.display.id         # firmware build
adb shell uname -r                            # kernel release
adb shell "su -c 'cat /proc/version'"         # build host/time (proves it is this kernel)
```

Manager side: open KernelSU-Next → the home screen must show
`Working`, `built-in (GKI2)` and a version matching the kernel
(for example `v3.4.2 (33355-5)`).

## Not supported

- Any other device (`fuxi`, `ishtar`, `shennong`, ...).
- Any firmware whose kernel is not exactly the version listed above. A stock
  OTA that changes the kernel requires a rebuild (see
  [`docs/BUILD-VERIFIED.md`](BUILD-VERIFIED.md) and [`docs/PINS.md`](PINS.md)).
- Flashing anything other than the `boot` partition together with this kernel.
- Re-locking the bootloader while this kernel is installed (EDL recovery only).
- Downgrading to an older full firmware package (Xiaomi anti-rollback).

## After a stock OTA

1. The device boots the stock kernel again — **root is lost, nothing is
   bricked**.
2. Read the new `uname -r` and compare with the release table above.
3. If the kernel version changed, the release must be rebuilt and re-verified
   before flashing. See [`docs/PINS.md`](PINS.md) "Re-pin rules".
4. Never flash an older release on top of newer firmware.
