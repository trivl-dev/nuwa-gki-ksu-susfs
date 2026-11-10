# FLASH-SAFETY — backup, test-boot, flash, rollback

Read this before touching the device. Prerequisites: bootloader unlocked, device
running `OS3.0.303.0.WMBMIXM` (or a newer build with the same kernel), battery
above 50%, and **a copy of the stock `boot.img`** within reach.

---

## 0. Ground truth

- `nuwa` is GKI 2.0: `boot.img` (header v4) holds only the raw kernel `Image`.
  The generic ramdisk lives in `init_boot`; the vendor ramdisk and DTB live in
  `vendor_boot`; overlays live in `dtbo`.
  → Replacing the kernel means writing **only `boot`**.
- KernelSU is built into the kernel, so the ramdisk is never modified.
- Changing the kernel invalidates the AVB hash in `vbmeta`: the device will show
  an orange/red state warning at boot. This is normal and not an error.
- **Never** re-lock the bootloader while a custom kernel is installed, and never
  flash firmware older than what is currently running (Xiaomi ARB).

---

## 1. Rollback assets (do this first)

`scripts/06_extract_stock_boot.sh` produces
`firmware/extracted/<package>/images/boot.img` from your own stock fastboot
package and verifies its MD5. Copy that file somewhere outside the build
directory (Windows drive, USB stick, cloud) — it is your way back.

Also keep the built custom image and the SUSFS module:
`build/nuwa-ksun-susfs_boot_<date>.img`, `build/susfs_guard_lkm.ko`.

If the device is already rooted and you want a byte-level backup of the current
slot, `scripts/08_device_backup.sh` can `dd` the live partitions over adb
(optional, requires root).

---

## 2. Test boot (writes nothing)

```bash
adb reboot bootloader
fastboot boot nuwa-ksun-susfs_boot_<date>.img
```

`fastboot boot` loads the image into RAM for one boot; nothing is written to
flash. Check the essentials:

```bash
adb shell uname -r            # must be 5.15.194-android13-8-00019-gf4321180a397-ab15212794
adb shell "cat /proc/version" # must show your build host/time, not Google's
```

Then verify hardware: touch, Wi-Fi, mobile data + calls, camera (front/back),
fingerprint, NFC, speaker/microphone, Bluetooth, fast charging.

Because the version string deliberately matches stock, `/proc/version`
(build user/host and timestamp) is the reliable way to confirm which kernel is
running.

---

## 3. Flash

```bash
fastboot flash boot nuwa-ksun-susfs_boot_<date>.img
fastboot reboot
```

Only `boot` is written. `fastboot flash boot` targets the active slot; to make
both slots identical use `fastboot getvar current-slot` and flash `boot_a` and
`boot_b` separately.

A/B safety note: keeping the inactive slot on the stock kernel is a valid
fallback (`fastboot set_active <slot>`); keeping the active slot custom is what
you normally want.

---

## 4. After the first boot

1. Install the **KernelSU-Next manager v3.4.2** APK (must match KSU_VERSION
   33355). It should report `33355 / v3.4.2 / Working`.
   If it reports "not installed", the kernel is not the custom one.
2. In the manager, enable **SUSFS** auto-load. Confirm:
   ```bash
   adb shell "ls -d /sys/module/susfs_guard_lkm"
   ```
3. With root available, confirm no module was rejected:
   ```bash
   adb shell "su -c 'dmesg | grep -iE \"disagrees about version|Unknown symbol\"'"
   ```
   The output must be empty. If it is not, the kernel is not KMI-compatible with
   the firmware — restore stock immediately.
4. Optional extras for hiding root (install in this order if you need them):
   ZygiskNext → Zygisk-Assistant → PlayIntegrityFork, plus the SUSFS WebUI
   module for per-feature toggles. Use only releases that match your manager
   version; do not install modules made for other devices.

---

## 5. Rollback

Normal rollback (bootloader still accessible):

```bash
fastboot flash boot stock-boot_nuwa_OS3.0.303.0.WMBMIXM.img
fastboot reboot
```

If the device boots but the kernel misbehaves, you can also switch to the other
slot (`fastboot set_active b`) when it still holds the stock kernel.

---

## 6. OTA behaviour

- A stock OTA writes the **inactive** slot and then switches to it. After the
  OTA you are on a stock kernel again: **root is lost, the device is not
  bricked**.
- Before rebuilding for a new OTA, check the new kernel version
  (`scripts/06_extract_stock_boot.sh` on the new package prints it). If the
  sublevel or build suffix changed, the ABI may have changed: re-pin the ACK
  commit (the hash is embedded in the version string), wipe `out/`, rebuild and
  re-run the KMI gate. Do not reuse an old image.
- Never flash an older full firmware package than the one currently installed.

---

## 7. Emergency

There is no official TWRP for the Xiaomi 13 series, and unofficial recoveries
for HyperOS 3 are unverified — do not rely on recovery.

1. Bootloader → fastboot usually remains reachable even with a broken system.
   Flash the stock `boot.img` (section 5).
2. If fastboot is unreachable, use MiFlash on Windows with the full stock
   package, "clean all" (never "clean all and lock").
3. Last resort for a hard brick: EDL mode (requires an authorised account).

---

## 8. Checklist

| Stage | Pass criteria |
|---|---|
| Build (PC) | 16 config asserts, KSU 33355/v3.4.2 in the smoke log, `Image` ~40 MB, vermagic identical to stock, KSU symbols in `System.map`, **KMI gate reports 0 mismatches**, SUSFS module vermagic matches, boot repack round-trips byte-identically |
| Test boot | `/proc/version` shows your build, all hardware works |
| Flash | `fastboot flash boot` succeeds, system boots normally |
| Root | Manager shows 33355 / v3.4.2 / Working, `dmesg` shows no version disagreements |
| SUSFS | `/sys/module/susfs_guard_lkm` exists after enabling auto-load |
