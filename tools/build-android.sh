#!/bin/bash
#
# build-android.sh - build the on-device tools with the flags this particular
# phone needs, and check the results before you push them.
#
#   ./tools/build-android.sh
#
# The two programs have different requirements, and getting either wrong
# produces a bare "Segmentation fault" with no explanation:
#
#   isdbt-dump        POSIX only -> static, any ARM cross-compiler will do
#   oneseg-api-probe  dlopens a Bionic .so -> dynamic Bionic binary, NDK only,
#                     and NON-PIE because Android 4.0.4 predates PIE support
#
# Anything it cannot build, it says why and carries on with the rest.
#
# SPDX-License-Identifier: Apache-2.0

set -u

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_off=$'\033[0m'
ok()   { printf '%sOK%s   %s\n'   "$c_grn" "$c_off" "$*"; }
bad()  { printf '%sFAIL%s %s\n'   "$c_red" "$c_off" "$*"; }
note() { printf '%sNOTE%s %s\n'   "$c_yel" "$c_off" "$*"; }

MY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$MY_DIR" || exit 1

built=0
failed=0

# ---------------------------------------------------------------------------
# isdbt-dump: static, no Android SDK needed
# ---------------------------------------------------------------------------

echo "=== isdbt-dump (static) ==="

CC_ARM=""
for c in arm-linux-gnueabihf-gcc arm-linux-gnueabi-gcc; do
    command -v "$c" >/dev/null 2>&1 && { CC_ARM="$c"; break; }
done

if [ -z "$CC_ARM" ]; then
    bad "no ARM cross-compiler found"
    note "  sudo apt install gcc-arm-linux-gnueabihf"
    failed=$((failed+1))
else
    if "$CC_ARM" -static -O2 -Wall -o isdbt-dump tools/isdbt-dump.c; then
        ok "built with $CC_ARM -> ./isdbt-dump"
        built=$((built+1))
    else
        bad "compile failed"
        failed=$((failed+1))
    fi
fi

# ---------------------------------------------------------------------------
# oneseg-api-probe: dynamic Bionic, non-PIE
# ---------------------------------------------------------------------------

echo
echo "=== oneseg-api-probe (dynamic, non-PIE, NDK) ==="

NDK="${ANDROID_NDK:-}"
if [ -z "$NDK" ]; then
    for d in "$HOME/android-ndk-r21e" "$HOME/Android/Sdk/ndk/21."* /opt/android-ndk-r21e; do
        [ -d "$d" ] && { NDK="$d"; break; }
    done
fi

CLANG=""
if [ -n "$NDK" ]; then
    for api in 16 17 18 19 21; do
        cand="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/armv7a-linux-androideabi$api-clang"
        [ -x "$cand" ] && { CLANG="$cand"; break; }
    done
fi

if [ -z "$CLANG" ]; then
    bad "no NDK clang found"
    if [ -n "${ANDROID_NDK:-}" ]; then
        note "  ANDROID_NDK is set to '$ANDROID_NDK', but no armv7a clang under"
        note "  toolchains/llvm/prebuilt/linux-x86_64/bin/ there."
    else
        note "  ANDROID_NDK is not set and no NDK was found in the usual places."
    fi
    note "  Get r21e (about 1GB, no account needed):"
    note ""
    note "    cd ~ && wget https://dl.google.com/android/repository/android-ndk-r21e-linux-x86_64.zip"
    note "    unzip -q android-ndk-r21e-linux-x86_64.zip"
    note "    export ANDROID_NDK=\"\$HOME/android-ndk-r21e\""
    note ""
    note "  Only oneseg-api-probe needs this. isdbt-dump above does not."
    failed=$((failed+1))
else
    echo "using $CLANG"
    # -fno-pie/-no-pie are the whole point: the Android 4.0.x linker cannot
    # load a position-independent executable and faults before main().
    if "$CLANG" -fno-pie -no-pie -O2 -Wall \
            -o oneseg-api-probe tools/oneseg-api-probe.c -ldl; then
        ok "built -> ./oneseg-api-probe"
        built=$((built+1))
    else
        bad "compile failed"
        failed=$((failed+1))
    fi
fi

# ---------------------------------------------------------------------------
# verify: the PIE trap is invisible until it crashes on the phone
# ---------------------------------------------------------------------------

echo
echo "=== checking the binaries ==="

# ET_EXEC is 2, ET_DYN is 3. A PIE executable is ET_DYN, and so is a shared
# library - which is why file(1) calls PIE "shared object" on some versions
# and "pie executable" on others. Reading e_type is exact and does not depend
# on which file(1) is installed.
elf_type() {
    local f="$1" b
    b="$(od -An -tu1 -j16 -N1 "$f" 2>/dev/null | tr -d ' \n')"
    printf '%s' "${b:-?}"
}

check_bin() {
    local f="$1" want_static="$2" et desc
    [ -f "$f" ] || return

    et="$(elf_type "$f")"
    desc=""
    command -v file >/dev/null 2>&1 && desc="$(file -b "$f")"

    if [ -n "$desc" ]; then
        case "$desc" in
            *ARM*) : ;;
            *) bad "$f is not an ARM binary: $desc"; failed=$((failed+1)); return ;;
        esac
    fi

    case "$et" in
        2) : ;;                        # ET_EXEC - what this device needs
        3) bad "$f is ET_DYN (PIE) - it will segfault instantly on Android 4.0.4"
           note "  The 4.0.x linker cannot load a position-independent executable."
           note "  Rebuild with -fno-pie -no-pie."
           [ -n "$desc" ] && note "  file(1) says: $desc"
           failed=$((failed+1)); return ;;
        *) note "$f: could not read the ELF type (got '$et') - check it by hand"
           return ;;
    esac

    if [ "$want_static" = "static" ]; then
        case "$desc" in
            *"statically linked"*) ok "$f: ARM, ET_EXEC, static" ;;
            "")                    ok "$f: ET_EXEC (file(1) not installed)" ;;
            *) note "$f: ET_EXEC but not static - may still work, -static is safer" ;;
        esac
    else
        case "$desc" in
            *"dynamically linked"*) ok "$f: ARM, ET_EXEC, dynamic" ;;
            "")                     ok "$f: ET_EXEC (file(1) not installed)" ;;
            *) note "$f: ET_EXEC but not dynamically linked - dlopen will not work" ;;
        esac
    fi
}

check_bin isdbt-dump static
check_bin oneseg-api-probe dynamic

# ---------------------------------------------------------------------------

echo
if [ "$built" -gt 0 ]; then
    echo "push what built:"
    [ -f isdbt-dump ] && echo "  adb push isdbt-dump /data/local/tmp/ && adb shell chmod 755 /data/local/tmp/isdbt-dump"
    [ -f oneseg-api-probe ] && echo "  adb push oneseg-api-probe /data/local/tmp/ && adb shell chmod 755 /data/local/tmp/oneseg-api-probe"
    echo
    echo "then, as root on the phone:"
    [ -f isdbt-dump ] && echo "  adb shell su -c '/data/local/tmp/isdbt-dump -s 10'"
    [ -f oneseg-api-probe ] && echo "  adb shell su -c '/data/local/tmp/oneseg-api-probe'"
fi

[ "$failed" -gt 0 ] && exit 1
exit 0
