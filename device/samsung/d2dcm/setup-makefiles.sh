#!/bin/bash
#
# Copyright (C) 2016 The CyanogenMod Project
# Copyright (C) 2017-2020 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#
# Regenerates vendor/samsung/d2dcm/ from proprietary-files.txt.

set -e

DEVICE=d2dcm
VENDOR=samsung

MY_DIR="${BASH_SOURCE%/*}"
if [[ ! -d "$MY_DIR" ]]; then MY_DIR="$PWD"; fi
MY_DIR="$(cd "$MY_DIR" && pwd)"

# Finding the top of the LineageOS tree.
#
# Every other device tree writes ANDROID_ROOT="$MY_DIR"/../../.. and stops
# there. That does not work here, because device/samsung/d2dcm is a symlink
# into this project's own repository: the kernel resolves the symlink first
# and only then applies "..", so the three levels climb out of lineage-sc-06
# instead of out of the LineageOS tree. The helper then gets looked for at
#
#   /home/you/lineage-sc-06/vendor/lineage/build/tools/extract_utils.sh
#
# which does not exist, and the script exits with
#
#   Unable to find helper script at device/samsung/d2dcm/../../../vendor/...
#   Run this from inside a synced LineageOS tree.
#
# even though you are, in fact, inside a synced LineageOS tree.
#
# So look for the helper rather than counting directories to it.
HELPER_REL=vendor/lineage/build/tools/extract_utils.sh

find_android_root() {
    local d

    # An explicit answer wins: envsetup.sh exports ANDROID_BUILD_TOP, and
    # LINEAGE_ROOT is there for running this without having lunched.
    for d in "$ANDROID_BUILD_TOP" "$LINEAGE_ROOT"; do
        if [ -n "$d" ] && [ -f "$d/$HELPER_REL" ]; then
            ( cd "$d" && pwd )
            return 0
        fi
    done

    # Otherwise walk up, first from where you are and then from the script's
    # own directory. bash's cd keeps symlinks in $PWD, so invoking this
    # through the symlinked path leaves MY_DIR inside the LineageOS tree and
    # the second walk finds the root as well.
    for d in "$PWD" "$MY_DIR"; do
        while [ -n "$d" ] && [ "$d" != "/" ]; do
            if [ -f "$d/$HELPER_REL" ]; then
                echo "$d"
                return 0
            fi
            d="$(dirname "$d")"
        done
    done

    return 1
}

if ! ANDROID_ROOT="$(find_android_root)"; then
    echo "Could not find the top of the LineageOS tree."
    echo
    echo "Looked for $HELPER_REL by walking up from:"
    echo "  $PWD"
    echo "  $MY_DIR"
    echo "and at \$ANDROID_BUILD_TOP / \$LINEAGE_ROOT."
    echo
    echo "Either cd into the synced tree first:"
    echo "  cd ~/lineage && source build/envsetup.sh && lunch lineage_d2dcm-userdebug"
    echo "or point at it explicitly:"
    echo "  LINEAGE_ROOT=~/lineage $0"
    exit 1
fi

HELPER="$ANDROID_ROOT/$HELPER_REL"
. "$HELPER"

setup_vendor "$DEVICE" "$VENDOR" "$ANDROID_ROOT" false true

# Headers
write_headers

write_makefiles "$MY_DIR"/proprietary-files.txt true

write_footers
