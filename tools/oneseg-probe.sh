#!/bin/bash
#
# oneseg-probe.sh - work out what the SC-06D 1seg stack is actually made of.
#
# Run this against a ROOTED, STOCK SC-06D, BEFORE flashing anything. Either
# stock release works: SC-06D shipped on Android 4.0.4 with 1seg already in
# place and was later updated to 4.1.2. Once LineageOS is on the device the
# stock stack is gone and this information cannot be recovered.
#
# The whole 1seg port hinges on one question that no public source answers:
# which files sit between /dev/isdbt and the user? This script answers it by
# pulling /system off the device and searching the binaries for references to
# the tuner device node, rather than guessing at file names.
#
# THIS RUNS ON YOUR COMPUTER, not on the phone. The phone only needs to be
# plugged in over USB with USB debugging enabled. Nothing is installed on it,
# and no Google account is involved - adb does not go through Play Services.
#
# Output lands in ./oneseg-report/.
#
# SPDX-License-Identifier: Apache-2.0

set -u

# Git Bash / MSYS on Windows rewrites any argument that looks like a Unix path,
# so "su -c 'ls /dev/isdbt'" would reach the phone as
# "ls C:/Program Files/Git/dev/isdbt" and every device-side command would fail
# for no visible reason. Turn that off. Harmless on Linux and macOS.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

REPORT_DIR="${ONESEG_REPORT_DIR:-$PWD/oneseg-report}"
PULL_DIR="$REPORT_DIR/system"
LOG="$REPORT_DIR/probe.log"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_off=$'\033[0m'

say()  { printf '%s\n' "$*" | tee -a "$LOG"; }
ok()   { printf '%s\n' "${c_grn}OK${c_off}   $*" | tee -a "$LOG"; }
warn() { printf '%s\n' "${c_yel}WARN${c_off} $*" | tee -a "$LOG"; }
die()  { printf '%s\n' "${c_red}ERR${c_off}  $*" | tee -a "$LOG" >&2; exit 1; }
hdr()  { printf '\n%s\n%s\n' "=== $* ===" "" | tee -a "$LOG"; }

# Run a command as root on the device. Root managers of that era differ in how
# they accept a command, so try the common spellings and keep whichever works.
SU_STYLE=""
dsu() {
    case "$SU_STYLE" in
        cmd)  adb shell "su -c '$*'" 2>/dev/null ;;
        dashc) adb shell "su -c \"$*\"" 2>/dev/null ;;
        pipe) printf '%s\n' "$*" | adb shell su 2>/dev/null ;;
        none) adb shell "$*" 2>/dev/null ;;
        *)    adb shell "$*" 2>/dev/null ;;
    esac
}

detect_su() {
    local probe
    for style in cmd dashc pipe none; do
        SU_STYLE="$style"
        probe="$(dsu id | tr -d '\r')"
        case "$probe" in
            *uid=0*) return 0 ;;
        esac
    done
    SU_STYLE="none"
    return 1
}

# ---------------------------------------------------------------------------
# 0. preflight
# ---------------------------------------------------------------------------

mkdir -p "$REPORT_DIR" || die "cannot create $REPORT_DIR"
: > "$LOG"

say "oneseg-probe.sh - SC-06D 1seg stack survey"
say "report: $REPORT_DIR"

if ! command -v adb >/dev/null 2>&1; then
    say ""
    say "adb is not in PATH. It is the only thing this script needs installed."
    say ""
    say "  Windows : download 'SDK Platform-Tools for Windows' from"
    say "            https://developer.android.com/tools/releases/platform-tools"
    say "            unzip it, and run this script from Git Bash in that folder."
    say "            (Use Git Bash, not WSL - WSL cannot see USB devices without"
    say "            extra usbipd setup.)"
    say "  macOS   : brew install --cask android-platform-tools"
    say "  Ubuntu  : sudo apt install adb"
    say "  Arch    : sudo pacman -S android-tools"
    say ""
    die "adb not found"
fi

hdr "0. device"

state="$(adb get-state 2>/dev/null | tr -d '\r')"
if [ "$state" != "device" ]; then
    say ""
    say "The phone is not visible to adb (state: '${state:-none}')."
    say ""
    say "  - USB debugging on?  設定 > 開発者向けオプション > USBデバッグ"
    say "  - Try 'adb kill-server' then 'adb devices'."
    say "  - Windows: the Samsung USB driver has to be installed."
    say "  - Android 4.0.4 has no 'allow USB debugging?' dialog (that arrived in"
    say "    4.2.2), so there is nothing to tap on the phone - if it still does"
    say "    not appear, it is the cable, the port, or the driver."
    say ""
    die "no device in 'device' state"
fi

adb shell getprop 2>/dev/null | tr -d '\r' > "$REPORT_DIR/getprop.txt"

model="$(grep -m1 'ro.product.model' "$REPORT_DIR/getprop.txt" | sed 's/.*\[\(.*\)\]/\1/')"
device="$(grep -m1 'ro.product.device' "$REPORT_DIR/getprop.txt" | sed 's/.*\[\(.*\)\]/\1/')"
rel="$(grep -m1 'ro.build.version.release' "$REPORT_DIR/getprop.txt" | sed 's/.*\[\(.*\)\]/\1/')"
fp="$(grep -m1 'ro.build.fingerprint' "$REPORT_DIR/getprop.txt" | sed 's/.*\[\(.*\)\]/\1/')"

say "model:       ${model:-unknown}"
say "device:      ${device:-unknown}"
say "android:     ${rel:-unknown}"
say "fingerprint: ${fp:-unknown}"

case "$model$device" in
    *SC-06D*|*d2dcm*|*d2om*) ok "SC-06D confirmed" ;;
    *) warn "this does not look like an SC-06D. Continuing anyway, but the results may be meaningless." ;;
esac

case "$rel" in
    # SC-06D shipped on 4.0.4 with 1seg and was updated to 4.1.2; either stock
    # release carries the full stack, so both are fine as an extraction source.
    4.0*) ok "stock Android $rel - 1seg shipped with this release, stack should be intact" ;;
    4.1*) ok "stock Android $rel (final docomo firmware) - stack should be intact" ;;
    4.*)  ok "stock-era Android ($rel) - the 1seg stack should be intact" ;;
    "")   warn "could not read the Android version" ;;
    *)    warn "Android $rel is not a stock SC-06D release (4.0.4 or 4.1.2)."
          warn "If this is already a custom ROM, the 1seg stack is likely gone." ;;
esac

if detect_su; then
    ok "root available (su style: $SU_STYLE)"
    HAVE_ROOT=1
else
    warn "no root. Much of /system is still readable, but /efs, /dev and the"
    warn "partition table will be missing, and those decide the partition"
    warn "sizes and the tuner node's ownership. Rooting first is recommended."
    HAVE_ROOT=0
fi

# ---------------------------------------------------------------------------
# 1. kernel and device node
# ---------------------------------------------------------------------------

hdr "1. tuner device node and kernel"

dsu 'cat /proc/devices' | tr -d '\r' > "$REPORT_DIR/proc-devices.txt"
if grep -qE '^[[:space:]]*225[[:space:]]' "$REPORT_DIR/proc-devices.txt"; then
    ok "char major 225 registered: $(grep -E '^[[:space:]]*225[[:space:]]' "$REPORT_DIR/proc-devices.txt" | tr -d '\r')"
else
    warn "char major 225 (isdbt) not present in /proc/devices"
fi

dsu 'ls -l /dev/isdbt' | tr -d '\r' > "$REPORT_DIR/dev-isdbt.txt"
if grep -q 'isdbt' "$REPORT_DIR/dev-isdbt.txt" 2>/dev/null; then
    ok "/dev/isdbt: $(cat "$REPORT_DIR/dev-isdbt.txt")"
    say "  ^ note the owner/group and mode - device/samsung/d2dcm/rootdir/etc/init.oneseg.rc"
    say "    must reproduce exactly this, or the ported stack will get EACCES."
else
    warn "/dev/isdbt not found (needs root to stat)"
fi

# The driver logs with a ">ISDBT<" prefix when CONFIG_ISDBT_NMI_DEBUG=y.
dsu 'dmesg' | tr -d '\r' > "$REPORT_DIR/dmesg.txt"
grep -i 'isdbt\|nmi326\|isdb' "$REPORT_DIR/dmesg.txt" > "$REPORT_DIR/dmesg-isdbt.txt" 2>/dev/null
if [ -s "$REPORT_DIR/dmesg-isdbt.txt" ]; then
    ok "kernel mentions the tuner ($(wc -l < "$REPORT_DIR/dmesg-isdbt.txt") lines) -> dmesg-isdbt.txt"
    head -20 "$REPORT_DIR/dmesg-isdbt.txt" | sed 's/^/    /' | tee -a "$LOG"
else
    warn "no isdbt/nmi326 lines in dmesg (the buffer may have wrapped; open the 1seg app and re-run)"
fi

dsu 'cat /sys/class/isdbt/isdbt/dev' | tr -d '\r' > "$REPORT_DIR/sys-class-isdbt.txt" 2>/dev/null
dsu 'ls -l /sys/bus/spi/devices/' | tr -d '\r' > "$REPORT_DIR/spi-devices.txt" 2>/dev/null

# ---------------------------------------------------------------------------
# 2. partitions - needed for BoardConfig.mk sizes and for the EFS backup
# ---------------------------------------------------------------------------

hdr "2. partitions"

dsu 'cat /proc/partitions' | tr -d '\r' > "$REPORT_DIR/proc-partitions.txt"
dsu 'ls -l /dev/block/platform/msm_sdcc.1/by-name/' | tr -d '\r' > "$REPORT_DIR/by-name.txt"
dsu 'cat /proc/mounts' | tr -d '\r' > "$REPORT_DIR/proc-mounts.txt"

if [ -s "$REPORT_DIR/by-name.txt" ]; then
    ok "partition map captured -> by-name.txt ($(wc -l < "$REPORT_DIR/by-name.txt") entries)"
    say "  Feed proc-partitions.txt into BoardConfig.mk; the sizes inherited from"
    say "  d2att are for a 16GB device and SC-06D is 32GB."
else
    warn "could not read the partition map (needs root)"
fi

# ---------------------------------------------------------------------------
# 3. what is running
# ---------------------------------------------------------------------------

hdr "3. processes, services, init"

dsu 'ps' | tr -d '\r' > "$REPORT_DIR/ps.txt"
dsu 'service list' | tr -d '\r' > "$REPORT_DIR/service-list.txt"
dsu 'cat /init.rc' | tr -d '\r' > "$REPORT_DIR/init.rc" 2>/dev/null
dsu 'ls /*.rc' | tr -d '\r' > "$REPORT_DIR/rc-files.txt" 2>/dev/null
dsu 'cat /ueventd.rc /ueventd.qcom.rc' | tr -d '\r' > "$REPORT_DIR/ueventd.txt" 2>/dev/null

grep -i 'isdb\|1seg\|oneseg\|dtv\|tvsvc\|nmi' "$REPORT_DIR/service-list.txt" "$REPORT_DIR/ps.txt" \
    > "$REPORT_DIR/services-isdbt.txt" 2>/dev/null
if [ -s "$REPORT_DIR/services-isdbt.txt" ]; then
    ok "1seg-looking services/processes found -> services-isdbt.txt"
    sed 's/^/    /' "$REPORT_DIR/services-isdbt.txt" | tee -a "$LOG"
else
    say "no 1seg service running right now (expected unless the TV app is open)"
fi

if grep -qi 'isdbt' "$REPORT_DIR/ueventd.txt" 2>/dev/null; then
    ok "stock ueventd rule for the tuner:"
    grep -i 'isdbt' "$REPORT_DIR/ueventd.txt" | sed 's/^/    /' | tee -a "$LOG"
    say "  ^ copy this verbatim into the d2dcm ueventd rule."
fi

# ---------------------------------------------------------------------------
# 4. pull /system
# ---------------------------------------------------------------------------

hdr "4. pulling /system (this takes a few minutes)"

mkdir -p "$PULL_DIR"

for d in lib etc framework bin; do
    say "pulling /system/$d ..."
    adb pull "/system/$d" "$PULL_DIR/$d" >>"$LOG" 2>&1 \
        && ok "/system/$d" \
        || warn "/system/$d could not be pulled in full"
done

# Listings for the big directories; the apks themselves are pulled selectively
# in step 5 once we know which ones matter.
for d in app priv-app vendor; do
    dsu "ls -l /system/$d" | tr -d '\r' > "$REPORT_DIR/ls-$d.txt" 2>/dev/null
done

# ---------------------------------------------------------------------------
# 5. find the stack by content, not by name
# ---------------------------------------------------------------------------

hdr "5. searching binaries for tuner references"

CAND="$REPORT_DIR/candidates.txt"
: > "$CAND"

# The decisive signal: anything that opens the tuner has to carry the literal
# string "/dev/isdbt". That is far more reliable than matching file names,
# because Samsung's Japanese builds do not consistently use "1seg" or "isdbt"
# in the names of the libraries that implement it.
say "searching for the literal /dev/isdbt ..."
if grep -rlI --binary-files=text -e '/dev/isdbt' "$PULL_DIR" 2>/dev/null > "$REPORT_DIR/hits-devnode.txt"; then :; fi
if [ -s "$REPORT_DIR/hits-devnode.txt" ]; then
    ok "files referencing /dev/isdbt:"
    sed 's/^/    /' "$REPORT_DIR/hits-devnode.txt" | tee -a "$LOG"
    cat "$REPORT_DIR/hits-devnode.txt" >> "$CAND"
else
    warn "nothing references /dev/isdbt in what was pulled."
    warn "The opener may live in /system/app or /system/priv-app (step 6),"
    warn "or the stack may open the node through a path built at runtime."
fi

say "searching for secondary markers ..."
for pat in 'isdbt' 'ISDBT' 'nmi326' 'NMI326' 'oneseg' 'OneSeg' '1seg' 'isdb-t' 'ISDB_T'; do
    grep -rlI --binary-files=text -e "$pat" "$PULL_DIR" 2>/dev/null >> "$REPORT_DIR/hits-strings.txt"
done
sort -u "$REPORT_DIR/hits-strings.txt" -o "$REPORT_DIR/hits-strings.txt" 2>/dev/null
if [ -s "$REPORT_DIR/hits-strings.txt" ]; then
    ok "$(wc -l < "$REPORT_DIR/hits-strings.txt") files mention the tuner -> hits-strings.txt"
    cat "$REPORT_DIR/hits-strings.txt" >> "$CAND"
fi

# Content-protection markers.
#
# NOTE: 1seg broadcasts are NOT scrambled - viewing needs no B-CAS card and no
# RMP key (RMP is a full-seg mechanism, and SC-06D has no full-seg). So these
# hits are not on the critical path. They are still worth collecting: DRM code
# marks the library that handles *recording*, which helps separate the layers
# and tells you which library you can safely leave behind.
say "searching for content-protection markers (informational) ..."
for pat in 'RMP' 'rmp_' 'MULTI2' 'multi2' 'B-CAS' 'bcas' 'BCAS' 'CAS_' 'descramble' 'Descramble' 'ecm' 'ECM' 'emm' 'EMM'; do
    grep -rlI --binary-files=text -e "$pat" "$PULL_DIR/lib" 2>/dev/null >> "$REPORT_DIR/hits-rmp.txt"
done
sort -u "$REPORT_DIR/hits-rmp.txt" -o "$REPORT_DIR/hits-rmp.txt" 2>/dev/null
if [ -s "$REPORT_DIR/hits-rmp.txt" ]; then
    ok "content-protection code -> hits-rmp.txt"
    sed 's/^/    /' "$REPORT_DIR/hits-rmp.txt" | tee -a "$LOG"
    say "  ^ recording DRM, most likely. Not needed to receive and watch."
else
    say "no content-protection strings found (fine - viewing does not need any)"
fi

sort -u "$CAND" -o "$CAND"

# ---------------------------------------------------------------------------
# 6. apps and framework glue
# ---------------------------------------------------------------------------

hdr "6. apps, framework, permissions"

grep -iE 'tv|dtv|1seg|oneseg|isdb|broadcast|dmb' "$REPORT_DIR/ls-app.txt" "$REPORT_DIR/ls-priv-app.txt" \
    > "$REPORT_DIR/apps-candidates.txt" 2>/dev/null
if [ -s "$REPORT_DIR/apps-candidates.txt" ]; then
    ok "candidate apps:"
    sed 's/^/    /' "$REPORT_DIR/apps-candidates.txt" | tee -a "$LOG"

    mkdir -p "$PULL_DIR/app"
    awk '{print $NF}' "$REPORT_DIR/apps-candidates.txt" | grep '\.apk$' | while read -r apk; do
        for base in app priv-app; do
            adb pull "/system/$base/$apk" "$PULL_DIR/app/$apk" >/dev/null 2>&1 && break
        done
    done
    ok "candidate apks pulled into system/app/"
else
    warn "no obviously TV-named apk. Widen the search by hand in ls-app.txt."
fi

if [ -d "$PULL_DIR/etc/permissions" ]; then
    grep -rliE '1seg|oneseg|isdb|dtv|tv' "$PULL_DIR/etc/permissions" > "$REPORT_DIR/permissions-candidates.txt" 2>/dev/null
    [ -s "$REPORT_DIR/permissions-candidates.txt" ] && {
        ok "permission xml candidates -> permissions-candidates.txt"
        sed 's/^/    /' "$REPORT_DIR/permissions-candidates.txt" | tee -a "$LOG"
    }
fi

if [ -d "$PULL_DIR/etc/firmware" ]; then
    ls -l "$PULL_DIR/etc/firmware" > "$REPORT_DIR/ls-firmware.txt" 2>/dev/null
    ok "firmware directory listed -> ls-firmware.txt"
    say "  The NMI326 needs a firmware image loaded over SPI at power-on."
    say "  Look for an unexplained blob here or under /system/etc."
fi

# ---------------------------------------------------------------------------
# 7. EFS - IMEI and radio calibration, and possibly tuner calibration
# ---------------------------------------------------------------------------

hdr "7. /efs"

if [ "$HAVE_ROOT" = "1" ]; then
    dsu 'ls -lR /efs' | tr -d '\r' > "$REPORT_DIR/efs-listing.txt" 2>/dev/null
    if [ -s "$REPORT_DIR/efs-listing.txt" ]; then
        ok "/efs listed -> efs-listing.txt ($(wc -l < "$REPORT_DIR/efs-listing.txt") lines)"
        say ""
        say "  ${c_yel}Back up /efs before you flash anything.${c_off} It holds the IMEI and the"
        say "  radio calibration, and may also hold tuner calibration data:"
        say ""
        say "    adb shell su -c 'dd if=/dev/block/platform/msm_sdcc.1/by-name/efs of=/sdcard/efs.img'"
        say "    adb pull /sdcard/efs.img"
        say ""
        say "  Keep that image somewhere safe and OFF the phone. It is not"
        say "  something you can recover or regenerate."
    fi
else
    warn "skipped - needs root"
fi

# ---------------------------------------------------------------------------
# 8. emit the blob list
# ---------------------------------------------------------------------------

hdr "8. proprietary-files.oneseg.txt"

OUT="$REPORT_DIR/proprietary-files.oneseg.txt"
{
    echo "# ISDB-T / 1seg blobs for SC-06D (d2dcm)"
    echo "#"
    echo "# Generated by tools/oneseg-probe.sh on $(date -u '+%Y-%m-%d %H:%M:%SZ')"
    echo "# Source device: ${model:-?} / ${fp:-?}"
    echo "#"
    echo "# Paste into device/samsung/d2dcm/proprietary-files.txt, under the"
    echo "# ISDB-T section. REVIEW THIS FIRST - it is generated from string"
    echo "# matches and will contain false positives (anything that merely"
    echo "# mentions \"tv\" or \"cas\")."
    echo ""
    if [ -s "$CAND" ]; then
        sed "s|^$PULL_DIR/||" "$CAND" | sed 's|^|# candidate: |' | sort -u
        echo ""
        echo "# --- as blob paths (strip the ones that are not really 1seg) ---"
        sed "s|^$PULL_DIR/|/|" "$CAND" | sed 's|^/|/|' | sort -u | while read -r p; do
            echo "${p#/}"
        done
    else
        echo "# (nothing found - see probe.log)"
    fi
} > "$OUT"

ok "wrote $OUT"

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------

hdr "summary"

say "report directory : $REPORT_DIR"
say "log              : $LOG"
say ""
say "Read these first, in this order:"
say "  1. dmesg-isdbt.txt      does the tuner driver exist and probe cleanly?"
say "  2. hits-devnode.txt     which library actually opens /dev/isdbt?"
say "  3. hits-rmp.txt         where does content protection live?"
say "  4. by-name.txt          real partition layout for BoardConfig.mk"
say ""
say "Then run:"
say "  ./tools/analyze-oneseg-blobs.py $REPORT_DIR"
say ""
say "to get each candidate library's DT_NEEDED list - that is what tells you"
say "how much Jelly Bean has to be dragged into Android 9 for it to load."
say ""
warn "Do not flash anything until you have backed up /efs and the stock ROM."
