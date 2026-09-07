#
# Copyright (C) 2014 The CyanogenMod Project
# Copyright (C) 2017 The LineageOS Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Board configuration for the docomo GALAXY S III (SC-06D), codename d2dcm.
#
# SC-06D is a member of the MSM8960 "d2" family, so almost everything is
# shared with d2att. This file inherits the unified d2att tree and then
# overrides only what is genuinely different on the docomo variant:
#
#   - the kernel defconfig (SC-06D has its own board file, board-m2_dcm.c)
#   - the OTA device assert
#   - the ISDB-T (1seg) tuner, which no other d2 variant has
#
# NOTE: this tree has not been built or booted on real hardware.
#       See docs/03-ビルド手順.md before trusting any value here.
#

LOCAL_PATH := device/samsung/d2dcm

# Inherit everything from the unified d2 tree first, then override below.
# d2att-unified already folds in d2-common and msm8960-common, so this single
# include brings in audio, camera, display, GPS, Bluetooth, Wi-Fi and recovery.
-include device/samsung/d2att/BoardConfig.mk

# Undo d2att's LOCAL_PATH so that anything below resolves against d2dcm.
LOCAL_PATH := device/samsung/d2dcm

# Kernel -----------------------------------------------------------------
# SC-06D is CONFIG_MACH_M2_DCM (arch/arm/mach-msm/board-m2_dcm.c), which is a
# different board file from the US variants. It has its own defconfig, and that
# defconfig is the one that already carries CONFIG_ISDBT_NMI=y for the 1seg
# tuner. Do not substitute lineageos_d2_defconfig here or 1seg support is lost.
TARGET_KERNEL_SOURCE := kernel/samsung/d2
TARGET_KERNEL_CONFIG := lineageos_d2dcm_defconfig

# OTA ---------------------------------------------------------------------
TARGET_OTA_ASSERT_DEVICE := d2dcm,d2lte

# Headers -----------------------------------------------------------------
# Deliberately NOT overridden. d2att sets TARGET_SPECIFIC_HEADER_PATH to its
# own include/ (samsung_lights.h, CameraParametersExtra.h, gps.h, device_perms.h)
# and SC-06D needs all of them. Assigning here with := would drop them and
# break the camera and lights HALs.

# RIL ---------------------------------------------------------------------
# Deliberately NOT overridden either. d2att's BOARD_RIL_CLASS points at
# ril/telephony/java/.../d2lteRIL.java, which is the Samsung Qualcomm RIL
# shared by the whole d2 family. docomo's difference is on the blob and
# property side (libsec-ril.so + rild.libargs + ro.ril.enable.dcm.feature),
# handled in system.prop and proprietary-files.txt.
#
# TODO(hardware): if docomo signalling turns out to need its own RIL subclass,
# add ril/telephony/java/com/android/internal/telephony/d2dcmRIL.java here and
# set BOARD_RIL_CLASS := ../../../device/samsung/d2dcm/ril at that point.

# Recovery ----------------------------------------------------------------
# Reuse d2att's fstab: the whole d2 family boots off msm_sdcc.1 and addresses
# partitions through by-name symlinks, so the paths are not variant-specific.
# TODO(hardware): confirm every by-name entry exists on SC-06D with
#   adb shell su -c 'ls -l /dev/block/platform/msm_sdcc.1/by-name/'
# and fork the file into this tree if anything is missing.
TARGET_RECOVERY_FSTAB := device/samsung/d2att/rootdir/etc/fstab.qcom

# ISDB-T / 1seg -----------------------------------------------------------
# Informational flag consumed by device.mk. The kernel driver itself is
# enabled through lineageos_d2dcm_defconfig, not from here.
BOARD_HAVE_ISDBT_NMI := true

# SELinux -----------------------------------------------------------------
# d2att-unified currently boots permissive (androidboot.selinux=permissive in
# BOARD_KERNEL_CMDLINE) and leaves BOARD_SEPOLICY_DIRS unset. The policy in
# sepolicy/ is therefore not compiled in by default; it is kept ready so that
# the build can be moved to enforcing once 1seg actually works.
#
# To switch to enforcing later:
#   1. drop androidboot.selinux=permissive from BOARD_KERNEL_CMDLINE
#   2. uncomment the line below
#
# BOARD_SEPOLICY_DIRS += device/samsung/d2dcm/sepolicy

# =========================================================================
# TODO(hardware): partition sizes are inherited from d2att, which is a 16GB
# device. SC-06D ships 32GB, so BOARD_USERDATAIMAGE_PARTITION_SIZE is almost
# certainly wrong. Read the real values off the device before the first build:
#
#   adb shell su -c 'cat /proc/partitions'
#   adb shell su -c 'ls -l /dev/block/platform/msm_sdcc.1/by-name/'
#   adb shell su -c 'cat /proc/emmc' 2>/dev/null
#
# then override the ones that differ here, for example:
#
#   BOARD_SYSTEMIMAGE_PARTITION_SIZE   := <bytes>
#   BOARD_USERDATAIMAGE_PARTITION_SIZE := <bytes>
#   BOARD_CACHEIMAGE_PARTITION_SIZE    := <bytes>
#
# An oversized system image simply fails to flash; an oversized userdata image
# can corrupt adjacent partitions. Do not guess these.
# =========================================================================
