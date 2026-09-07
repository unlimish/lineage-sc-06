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

# Which LineageOS branch was this tree initialised on?
#
# Do NOT read this off the first revision= in default.xml. In lineage-16.0
# that attribute belongs to the <default>/github remote and reads
# "refs/tags/android-9.0.0_r46" - the AOSP tag Pie was cut from, which is
# exactly right for a 16.0 tree and looks exactly wrong to a naive grep.
# The branch repo init was given is recorded by git instead.
rev=""
if [ -d "$ROOT/.repo/manifests" ]; then
    rev="$(git -C "$ROOT/.repo/manifests" config --get branch.default.merge 2>/dev/null)"
    rev="${rev#refs/heads/}"
fi
if [ -z "$rev" ] && [ -f "$ROOT/.repo/manifests/default.xml" ]; then
    # Fallback: the lineage remote carries the branch for LineageOS's own
    # projects, whatever the AOSP default says.
    rev="$(grep -o 'name="lineage"[^>]*revision="[^"]*"' \
             "$ROOT/.repo/manifests/default.xml" 2>/dev/null \
           | head -1 | sed 's/.*revision="//; s/".*//; s|refs/heads/||')"
fi

case "$rev" in
    *16.0*) ok "manifest branch: $rev" ;;
    "")     note "could not read the manifest branch" ;;
    *)      note "manifest branch is '$rev', expected lineage-16.0"
            info "Nothing newer than 16.0 exists for MSM8960 - see docs/01." ;;
esac

# extract-files.sh needs this and says so only after you have gone looking
# for a device.
if [ -f "$ROOT/vendor/lineage/build/tools/extract_utils.sh" ]; then
    ok "vendor/lineage/build/tools/extract_utils.sh (blob extraction helper)"
else
    bad "vendor/lineage/build/tools/extract_utils.sh missing"
    info "extract-files.sh cannot run without it. Re-sync vendor/lineage."
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

# Which directory the shared blobs must land in is not a guess -
# d2att-unified's device.mk reads them back from exactly these two:
#
#   $(call inherit-product-if-exists, vendor/samsung/d2-common/d2-common-vendor.mk)
#   $(call inherit-product-if-exists, vendor/samsung/msm8960-common/msm8960-common-vendor.mk)
#
# "if-exists" is the dangerous part. With no blobs the build still succeeds
# and hands you a flashable zip with no graphics, audio or radio, and
# nothing says so at build time. This check is the only thing that will.
D2COMMON=""
for d in msm8960-common d2-common; do
    [ -d "$ROOT/vendor/samsung/$d" ] && D2COMMON="$ROOT/vendor/samsung/$d" && break
done
if [ -n "$D2COMMON" ]; then
    ok "vendor/samsung/$(basename "$D2COMMON") (d2 common blobs)"
else
    bad "d2 common blobs not extracted - no vendor/samsung/msm8960-common"
    info "The build will still SUCCEED without them and produce a ROM with"
    info "no graphics, audio or radio: device.mk uses inherit-product-if-exists."
    info "d2att's own extract-files.sh does not run (it is a CyanogenMod-era"
    info "script for a tree layout that no longer exists). Use:"
    info "  tools/extract-d2att.sh"
fi

[ -d "$ROOT/vendor/samsung/d2dcm" ] \
    && ok "vendor/samsung/d2dcm (docomo blobs)" \
    || note "docomo blobs not extracted yet - run device/samsung/d2dcm/extract-files.sh"

# Can the extraction scripts actually be run?
#
#   $ ./extract-files.sh
#   bash: ./extract-files.sh: Permission denied
#
# Two different causes, and the message is the same for both: the file was
# committed without its executable bit, or the tree is on a noexec mount.
# Distinguish them, because the fixes are nothing alike.
noexec=0
probe="$ROOT/.verify-tree-exec-probe.$$"
if printf '#!/bin/sh\nexit 0\n' > "$probe" 2>/dev/null; then
    chmod +x "$probe" 2>/dev/null
    "$probe" 2>/dev/null || noexec=1
    rm -f "$probe"
fi

notx=""
for f in device/samsung/d2att/extract-files.sh \
         device/samsung/d2att/setup-makefiles.sh \
         device/samsung/d2dcm/extract-files.sh \
         device/samsung/d2dcm/setup-makefiles.sh; do
    [ -f "$ROOT/$f" ] || continue
    [ -x "$ROOT/$f" ] || notx="$notx $f"
done

if [ "$noexec" = 1 ]; then
    bad "$ROOT is on a noexec mount - no script in the tree can run"
    info "chmod will not help. Remount, or invoke through the interpreter:"
    info "  cd $ROOT/device/samsung/d2dcm && bash ./extract-files.sh"
elif [ -n "$notx" ]; then
    note "extraction scripts are not executable:$notx"
    info "Upstream device trees are not consistent about committing the"
    info "executable bit. Either run them through bash:"
    info "  cd $ROOT/device/samsung/d2att && bash ./extract-files.sh"
    info "or set the bit once:"
    for f in $notx; do
        info "  chmod +x $ROOT/$f"
    done
else
    ok "extraction scripts are executable"
fi

# d2att-unified still points at the CyanogenMod path.
#
#   $ ./extract-files.sh
#   Unable to find helper script at ./../../../vendor/cm/build/tools/extract_utils.sh
#
# LineageOS renamed vendor/cm to vendor/lineage back in 14.1; that tree was
# never updated. Nothing is missing from the sync - the path is just old.
stale=""
for f in device/samsung/d2att/extract-files.sh \
         device/samsung/d2att/setup-makefiles.sh; do
    [ -f "$ROOT/$f" ] || continue
    grep -q 'vendor/cm/build/tools' "$ROOT/$f" 2>/dev/null && stale="$stale $ROOT/$f"
done

if [ -n "$stale" ]; then
    note "d2att extraction scripts still reference vendor/cm (CyanogenMod path)"
    info "Renamed to vendor/lineage in LineageOS 14.1. Point them at it:"
    info "  sed -i 's|vendor/cm/build/tools|vendor/lineage/build/tools|' \\"
    info "     $stale"
    info "repo sync --force-sync reverts this, so redo it after a re-sync."
fi

# The three libraries this project exists for.
if [ -d "$ROOT/vendor/samsung/d2dcm" ]; then
    missing=""
    for l in libonesegdmxdriver.so libonesegutils.so libPGL.so; do
        find "$ROOT/vendor/samsung/d2dcm" -name "$l" -print -quit 2>/dev/null \
            | grep -q . || missing="$missing $l"
    done
    if [ -z "$missing" ]; then
        ok "1seg libraries extracted (libonesegdmxdriver, libonesegutils, libPGL)"
    else
        bad "1seg libraries NOT extracted:$missing"
        info "Without these the ROM builds fine and cannot receive anything."
        info "Check they are uncommented in d2dcm/proprietary-files.txt, then"
        info "re-run device/samsung/d2dcm/extract-files.sh with the phone attached."
    fi
fi

# Two vendor trees, one /system. extract_utils.sh writes a PRODUCT_COPY_FILES
# line per blob, and if d2att and d2dcm both claim the same destination the
# build fails on a duplicate entry - a long way from anything that names the
# blob list. d2dcm is meant to hold only what is docomo-specific, so an
# overlap is a bug in proprietary-files.txt rather than something to work
# around in the makefiles.
A="$D2COMMON/proprietary"
B="$ROOT/vendor/samsung/d2dcm/proprietary"
if [ -n "$D2COMMON" ] && [ -d "$A" ] && [ -d "$B" ]; then
    dupes="$( { ( cd "$A" && find . -type f | sed 's|^\./||' )
                ( cd "$B" && find . -type f | sed 's|^\./||' ) ; } \
              | sort | uniq -d )"
    if [ -n "$dupes" ]; then
        bad "the same blob is claimed by both $(basename "$D2COMMON") and d2dcm:"
        echo "$dupes" | head -20 | sed 's/^/       /'
        info "Remove these from d2dcm/proprietary-files.txt - the shared d2"
        info "blobs are d2att-unified's job - then re-extract d2dcm."
    else
        ok "no blob claimed by both $(basename "$D2COMMON") and d2dcm"
    fi
fi

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
