# kernel/patches

Patches for `kernel/samsung/d2` (branch `lineage-16.0`).

Apply from the kernel root:

```bash
cd <LINEAGE_ROOT>/kernel/samsung/d2
git apply /path/to/lineage-sc-06/kernel/patches/0001-*.patch
```

---

## There is no patch to enable the 1seg driver — it is already enabled

This is worth stating plainly, because it is the first thing you would expect
to find here.

`arch/arm/configs/lineageos_d2dcm_defconfig` on the `lineage-16.0` branch
already contains:

```
CONFIG_MACH_M2_DCM=y
CONFIG_ISDBT_NMI=y
CONFIG_ISDBT_NMI_DEBUG=y
```

and `drivers/media/nmi326/` is present and wired into `drivers/media/Kconfig`
and `drivers/media/Makefile`. `arch/arm/mach-msm/board-m2_dcm.c` registers the
SPI device and the power/reset GPIOs.

So building `lineage_d2dcm` produces a kernel with a working `/dev/isdbt`
without any patch at all. (For contrast, the CM13-era
`cyanogen_d2dcm_defconfig` had `# CONFIG_ISDBT_NMI is not set` — someone
turned it on during the Pie port.)

What is missing on Android 9 is the entire userspace above that node. No
kernel patch can supply it. See `docs/02-ワンセグの構造と壁.md`.

---

## 0001-nmi326-add-optional-SPI-protocol-tracing.patch

Adds `nmi326.trace` / `nmi326.trace_max` module parameters that hex-dump the
SPI traffic between the closed userspace library and the tuner.

This is the tool for step 6 route 2 in `docs/05-ワンセグ移植の手順.md`: if the
stock libraries cannot be made to load on Pie, the fallback is to reimplement
them, and that requires knowing what they actually send.

**The most valuable way to use it is on the stock ROM, not on LineageOS.**
Build a stock-compatible kernel with this patch, boot Android 4.1.2, open the
stock 1seg app, and record a full tune-and-play sequence. That capture is
ground truth for the protocol, and it cannot be obtained any other way once
the stock ROM is gone.

```bash
adb shell su -c 'echo 1 > /sys/module/nmi326_spi_drv/parameters/trace'
adb shell su -c 'echo 256 > /sys/module/nmi326_spi_drv/parameters/trace_max'
# open the 1seg app, tune a channel, watch for ~30 seconds
adb shell su -c 'dmesg' > oneseg-spi-trace.txt
```

Default `trace_max` is 64 bytes per transfer. Raise it to see more of each
control exchange; lower it (or leave tracing off) once TS payload starts
flowing, or the ring buffer fills with video data in seconds.

Off by default, so the patch is safe to carry in a normal build.
