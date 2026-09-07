#!/bin/bash
#
# Copyright (C) 2016 The CyanogenMod Project
# Copyright (C) 2017-2020 The LineageOS Project
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
# Pulls the docomo-specific blobs listed in proprietary-files.txt out of a
# stock SC-06D (or an extracted stock ROM) into vendor/samsung/d2dcm/.
#
# The shared d2/msm8960 blobs are the d2att tree's business - run its own
# extract-files.sh for those.

set -e

DEVICE=d2dcm
VENDOR=samsung

MY_DIR="${BASH_SOURCE%/*}"
if [[ ! -d "$MY_DIR" ]]; then MY_DIR="$PWD"; fi

ANDROID_ROOT="$MY_DIR"/../../..

HELPER="$ANDROID_ROOT"/vendor/lineage/build/tools/extract_utils.sh
if [ ! -f "$HELPER" ]; then
    echo "Unable to find helper script at $HELPER"
    echo "Run this from inside a synced LineageOS tree."
    exit 1
fi
. "$HELPER"

SRC=adb
SECTION=
KANG=

while [ "$#" -gt 0 ]; do
    case "$1" in
        -n | --no-cleanup )     CLEAN_VENDOR=false ;;
        -k | --kang )           KANG="--kang" ;;
        -s | --section )        SECTION="$2" ; shift ; CLEAN_VENDOR=false ;;
        * )                     SRC="$1" ;;
    esac
    shift
done

if [ -z "$SRC" ]; then
    SRC=adb
fi

setup_vendor "$DEVICE" "$VENDOR" "$ANDROID_ROOT" false "$CLEAN_VENDOR"

extract "$MY_DIR"/proprietary-files.txt "$SRC" "$KANG" --section "$SECTION"

"$MY_DIR"/setup-makefiles.sh
