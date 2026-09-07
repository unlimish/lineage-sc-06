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

ANDROID_ROOT="$MY_DIR"/../../..

HELPER="$ANDROID_ROOT"/vendor/lineage/build/tools/extract_utils.sh
if [ ! -f "$HELPER" ]; then
    echo "Unable to find helper script at $HELPER"
    exit 1
fi
. "$HELPER"

setup_vendor "$DEVICE" "$VENDOR" "$ANDROID_ROOT" false true

# Headers
write_headers

write_makefiles "$MY_DIR"/proprietary-files.txt true

write_footers
