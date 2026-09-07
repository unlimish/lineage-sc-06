#!/bin/bash
#
# verify-tree.sh - check that a synced LineageOS tree has everything the
# d2dcm build needs, before you spend four hours finding out it does not.
#
#   ./tools/verify-tree.sh /path/to/lineage
#
# The check that matters most is the last one: that the kernel really will
# build the ISDB-T driver. Getting lineageos_d2_defconfig instead of
# lineageos_d2dcm_defconfig produces a perfectly good ROM with no 1seg
# support and no error message to tell you.
#
# SPDX-License-Identifier: Apache-2.0

set -u

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_off=$'\033[0m'
fail=0; warn=0

ok()   { printf '%sOK%s   %s\n'   "$c_grn" "$c_off" "$*"; }
bad()  { printf '%sFAIL%s %s\n'   "$c_red" "$c_off" "$*"; fail=$((fail+1)); }
note() { printf '%sWARN%s %s\n'   "$c_yel" "$c_off" "$*"; warn=$((warn+1)); }
info() { printf '     %s\n' "$*"; }

if [ $# -ne 1 ]; then
    echo "usage: $0 <LINEAGE_ROOT>" >&2
    exit 2
fi
ROOT="$1"

echo "checking $ROOT"
echo

# --- tree itself -----------------------------------------------------------

[ -d "$ROOT/.repo" ]        && ok ".repo present"           || bad ".repo missing - not a repo tree"
[ -d "$ROOT/build" ]        && ok "build/ present"          || bad "build/ missing - repo sync did not finish"
[ -d "$ROOT/vendor/lineage" ] && ok "vendor/lineage present" || bad "vendor/lineage missing"

if [ -f "$ROOT/.repo/manifests/default.xml" ]; then
    rev="$(grep -o 'revision="[^"]*"' "$ROOT/.repo/manifests/default.xml" | head -1 | cut -d'"' -f2)"
    case "$rev" in
        *16.0*) ok "manifest revision: $rev" ;;
        "")     note "could not read the manifest revision" ;;
        *)      note "manifest revision is '$rev', expected lineage-16.0"
                info "Nothing newer than 16.0 exists for MSM8960 - see docs/01." ;;
    esac
fi

# --- device trees ----------------------------------------------------------

if [ -d "$ROOT/device/samsung/d2att" ]; then
    ok "device/samsung/d2att (unified d2 tree)"
else
    bad "device/samsung/d2att missing - d2dcm inherits from it"
    info "Install manifests/local_manifest.xml and re-run repo sync."
fi

if [ -e "$ROOT/device/samsung/d2dcm" ]; then
    if [ -L "$ROOT/device/samsung/d2dcm" ]; then
        ok "device/samsung/d2dcm -> $(readlink "$ROOT/device/samsung/d2dcm")"
    else
        ok "device/samsung/d2dcm (real directory)"
    fi
    for f in BoardConfig.mk device.mk lineage_d2dcm.mk AndroidProducts.mk; do
        [ -f "$ROOT/device/samsung/d2dcm/$f" ] \
            && ok "  d2dcm/$f" \
            || bad "  d2dcm/$f missing"
    done
else
    bad "device/samsung/d2dcm missing"
    info "Run: ./tools/link-device-tree.sh $ROOT"
fi

[ -d "$ROOT/device/samsung/qcom-common" ] \
    && ok "device/samsung/qcom-common" \
    || bad "device/samsung/qcom-common missing"

[ -d "$ROOT/external/stlport" ] \
    && ok "external/stlport (Jelly Bean blob compatibility)" \
    || note "external/stlport missing - some Samsung blobs need it"

# --- kernel: the part that decides whether 1seg is even possible -----------

echo
echo "kernel:"

K="$ROOT/kernel/samsung/d2"
if [ ! -d "$K" ]; then
    bad "kernel/samsung/d2 missing"
else
    ok "kernel/samsung/d2 present"

    if [ -d "$K/drivers/media/nmi326" ]; then
        ok "  drivers/media/nmi326 (ISDB-T tuner driver)"
        for f in nmi326.c nmi326.h nmi326_spi_drv.c Kconfig Makefile; do
            [ -f "$K/drivers/media/nmi326/$f" ] || bad "    nmi326/$f missing"
        done
    else
        bad "  drivers/media/nmi326 MISSING - this kernel cannot do 1seg"
        info "  You have the wrong d2 kernel. Use"
        info "  Samsung-Galaxy-S3-MSM8960/android_kernel_samsung_d2 @ lineage-16.0."
    fi

    [ -f "$K/arch/arm/mach-msm/board-m2_dcm.c" ] \
        && ok "  board-m2_dcm.c (SC-06D board file)" \
        || bad "  board-m2_dcm.c MISSING - SC-06D is not supported by this kernel"

    DEF="$K/arch/arm/configs/lineageos_d2dcm_defconfig"
    if [ -f "$DEF" ]; then
        ok "  lineageos_d2dcm_defconfig"
        if grep -q '^CONFIG_ISDBT_NMI=y' "$DEF"; then
            ok "    CONFIG_ISDBT_NMI=y  <- 1seg driver will be built in"
        else
            bad "    CONFIG_ISDBT_NMI is not enabled in the defconfig"
            info "    Without this there is no /dev/isdbt and no 1seg, ever."
        fi
        grep -q '^CONFIG_MACH_M2_DCM=y' "$DEF" \
            && ok "    CONFIG_MACH_M2_DCM=y" \
            || bad "    CONFIG_MACH_M2_DCM is not set"
        grep -q '^CONFIG_SPI_QUP=y' "$DEF" \
            && ok "    CONFIG_SPI_QUP=y (tuner is on SPI)" \
            || note "    CONFIG_SPI_QUP not set - the tuner is behind GSBI8 SPI"
    else
        bad "  lineageos_d2dcm_defconfig MISSING"
    fi
fi

# --- the defconfig the build will actually use ----------------------------

echo
echo "build wiring:"

BC="$ROOT/device/samsung/d2dcm/BoardConfig.mk"
if [ -f "$BC" ]; then
    # Last assignment wins in make, so check the effective one.
    eff="$(grep -E '^[[:space:]]*TARGET_KERNEL_CONFIG[[:space:]]*:?=' "$BC" | tail -1 | sed 's/.*=[[:space:]]*//')"
    case "$eff" in
        lineageos_d2dcm_defconfig)
            ok "TARGET_KERNEL_CONFIG = $eff" ;;
        "")
            note "TARGET_KERNEL_CONFIG not set in d2dcm/BoardConfig.mk"
            info "It would fall through to d2att's lineageos_d2_defconfig, which"
            info "has no 1seg support." ;;
        *)
            bad "TARGET_KERNEL_CONFIG = $eff"
            info "Expected lineageos_d2dcm_defconfig. Any other value silently"
            info "drops 1seg support and SC-06D's board file." ;;
    esac
fi

# --- did the sync actually finish? ----------------------------------------
#
# repo reports failures at the end of a long run and they scroll away. A tree
# that synced 713 of 715 projects looks fine until the build fails on
# something unrelated-looking hours later, so check for the empty checkouts
# that a partial sync leaves behind.

echo
echo "sync completeness:"

incomplete=0
for p in external/chromium-webview/prebuilt/arm build/make frameworks/base \
         external/stlport hardware/qcom-caf; do
    d="$ROOT/$p"
    [ -e "$d" ] || continue
    if [ -z "$(ls -A "$d" 2>/dev/null)" ]; then
        bad "$p is present but EMPTY - that project did not check out"
        incomplete=$((incomplete+1))
    fi
done

if [ "$incomplete" -gt 0 ]; then
    info "A common cause is git-lfs missing: the chromium-webview prebuilts are"
    info "stored in LFS and fail at checkout with"
    info "  git-lfs filter-process --skip: 1: git-lfs: not found"
    info "Fix and re-sync - only the failed projects are refetched:"
    info "  sudo apt install git-lfs && git lfs install"
    info "  cd $ROOT && repo sync -c -j4 --no-clone-bundle --no-tags --force-sync"
    fail=$((fail+incomplete))
else
    ok "no empty project directories"
fi

# --- blobs ----------------------------------------------------------------

echo
echo "vendor blobs:"

if [ -d "$ROOT/vendor/samsung/d2att" ] || [ -d "$ROOT/vendor/samsung/d2gsm" ]; then
    ok "vendor/samsung (d2 common blobs)"
else
    note "d2 common blobs not extracted yet"
fi

[ -d "$ROOT/vendor/samsung/d2dcm" ] \
    && ok "vendor/samsung/d2dcm (docomo blobs)" \
    || note "docomo blobs not extracted yet - run device/samsung/d2dcm/extract-files.sh"

# --- summary --------------------------------------------------------------

echo
if [ "$fail" -gt 0 ]; then
    printf '%s%d check(s) failed%s, %d warning(s)\n' "$c_red" "$fail" "$c_off" "$warn"
    exit 1
fi
printf '%sall checks passed%s' "$c_grn" "$c_off"
[ "$warn" -gt 0 ] && printf ' (%d warning(s))' "$warn"
printf '\n\n'
echo "next:"
echo "  cd $ROOT && source build/envsetup.sh && lunch lineage_d2dcm-userdebug"
exit 0
