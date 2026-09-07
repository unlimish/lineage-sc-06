#!/bin/bash
#
# extract-d2att.sh - pull the shared d2 / msm8960 blobs off the phone.
#
# SPDX-License-Identifier: Apache-2.0
#
# Why this exists instead of device/samsung/d2att/extract-files.sh:
#
# That script does not run. It is a CyanogenMod-era script for a tree that
# used to be split into msm8960-common, d2-common and a directory per
# carrier, and it still reads
#
#     setup_vendor "$PLATFORM_COMMON" "$VENDOR" "$CM_ROOT" true
#     extract      "$MY_DIR"/../$DEVICE/proprietary-files.txt "$SRC"
#
# while assigning none of $PLATFORM_COMMON, $DEVICE, $DEVICE_COMMON or
# $VENDOR anywhere. The unified tree has collapsed all of those into one
# proprietary-files.txt at its top level, so the first setup_vendor call
# gets an empty device name and extract_utils.sh stops with
#
#     $DEVICE must be set before including this script!
#
# Setting the variables in the environment does not help either: the later
# half of the script would then extract the same list a second time into
# vendor/samsung/d2gsm, a directory nothing reads.
#
# Where the blobs have to end up is not a guess. device.mk says:
#
#     $(call inherit-product-if-exists, vendor/samsung/d2-common/d2-common-vendor.mk)
#     $(call inherit-product-if-exists, vendor/samsung/msm8960-common/msm8960-common-vendor.mk)
#
# One list, and msm8960-common is the platform-wide half of that pair, so
# that is the name to write.
#
# Read "if-exists" carefully. With no blobs at all the build still succeeds
# and hands you a flashable zip with no graphics, audio, or radio. Nothing
# will tell you at build time. verify-tree.sh checks for them instead.
#
# This script lives here rather than being sed'ed into the d2att tree
# because `repo sync --force-sync` reverts anything changed there.
#
# Usage:
#
#   ./tools/extract-d2att.sh                     from the phone over adb
#   ./tools/extract-d2att.sh /path/to/stock/rom  from an extracted ROM
#
#   ./tools/extract-d2att.sh -l LIST [SRC]       use a different blob list
#
#   LINEAGE_ROOT=~/lineage ./tools/extract-d2att.sh    if you have not lunched
#
# On a 4.0.4 handset this fails on 53 of the 114 files, all of them under
# vendor/lib/: that list targets stock 4.1.2, where Qualcomm's libraries
# moved from lib/ to vendor/lib/. 95 of the 114 are prebuilt in
# vendor/samsung/d2-common, which local_manifest.xml now syncs, so on 4.0.4
# reach for that rather than this. What remains is the Adreno userspace -
# see tools/d2att-gpu-from-ics.txt.

set -e

# NOT named VENDOR or COMMON. extract_utils.sh owns both of those names -
# it initialises COMMON=-1 at source time - so a plain COMMON=msm8960-common
# set before the source is silently replaced, and everything lands in
# vendor/samsung/-1 instead. Prefix them out of its way.
D2_VENDOR=samsung
D2_COMMON=msm8960-common

# The guard write_headers puts around the generated Android.mk. A common
# vendor tree has no single device to infer it from, so it must be given
# one: without it extract_utils stops with "Argument with devices to be
# added to guard must be set!".
D2_GUARD_DEVICES="d2att d2can d2cri d2dcm d2lte d2mtr d2spr d2tmo d2usc d2vzw"

HELPER_REL=vendor/lineage/build/tools/extract_utils.sh

find_android_root() {
    local d
    for d in "$ANDROID_BUILD_TOP" "$LINEAGE_ROOT"; do
        if [ -n "$d" ] && [ -f "$d/$HELPER_REL" ]; then
            ( cd "$d" && pwd )
            return 0
        fi
    done
    for d in "$PWD" "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; do
        while [ -n "$d" ] && [ "$d" != "/" ]; do
            [ -f "$d/$HELPER_REL" ] && { echo "$d"; return 0; }
            d="$(dirname "$d")"
        done
    done
    return 1
}

if ! ANDROID_ROOT="$(find_android_root)"; then
    echo "Could not find the top of the LineageOS tree."
    echo
    echo "  cd ~/lineage && source build/envsetup.sh && lunch lineage_d2dcm-userdebug"
    echo "or"
    echo "  LINEAGE_ROOT=~/lineage $0"
    exit 1
fi

D2ATT="$ANDROID_ROOT/device/samsung/d2att"
LIST="$D2ATT/proprietary-files.txt"

LIST_OVERRIDE=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -l|--list) LIST_OVERRIDE="$2"; shift 2 ;;
        -h|--help) sed -n '3,40p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *)         break ;;
    esac
done

if [ -n "$LIST_OVERRIDE" ]; then
    if [ ! -f "$LIST_OVERRIDE" ]; then
        echo "no such list: $LIST_OVERRIDE" >&2
        exit 1
    fi
    LIST="$(cd "$(dirname "$LIST_OVERRIDE")" && pwd)/$(basename "$LIST_OVERRIDE")"
fi

if [ ! -f "$LIST" ]; then
    echo "No $LIST"
    echo "device/samsung/d2att is the d2att-unified tree - check it synced."
    exit 1
fi

SRC="${1:-adb}"

if [ "$SRC" = adb ]; then
    command -v adb >/dev/null 2>&1 || { echo "adb not found in PATH" >&2; exit 1; }
    state="$(adb get-state 2>/dev/null | tr -d '\r')"
    if [ "$state" != device ]; then
        echo "no device (adb state: ${state:-none})" >&2
        echo "Connect the SC-06D with USB debugging on, and root available." >&2
        exit 1
    fi
fi

# shellcheck source=/dev/null
. "$ANDROID_ROOT/$HELPER_REL"

echo "extracting $(grep -cvE '^[[:space:]]*#|^[[:space:]]*$' "$LIST") blobs"
echo "  from : $SRC"
echo "  into : $ANDROID_ROOT/vendor/$D2_VENDOR/$D2_COMMON"
echo

# true = this is a "common" vendor tree, so the generated makefile is named
# after $D2_COMMON rather than after a device.
setup_vendor "$D2_COMMON" "$D2_VENDOR" "$ANDROID_ROOT" true

extract "$LIST" "$SRC"

# d2att's setup-makefiles.sh is unusable for the same reason as its
# extract-files.sh, so generate the makefiles here.
setup_vendor "$D2_COMMON" "$D2_VENDOR" "$ANDROID_ROOT" true
write_headers "$D2_GUARD_DEVICES"
write_makefiles "$LIST" true
write_footers

echo
echo "done. Check it with:"
echo "  tools/verify-tree.sh $ANDROID_ROOT"
