#!/bin/bash
#
# oneseg-logcat.sh - watch the stock 1seg stack narrate itself.
#
# The SC-06D's 1seg software was shipped with its debug logging left on, and
# it is unusually good: every line carries the source file and line number it
# came from.
#
#   I/OneSeg: [4][H][439791.759]  DMX [DriverWrap, 396] After Polling.
#             retval=[0]. events[0].fd=[17], events[0].revents=[0x0]
#   I/OneSeg: [4][H][439791.809] CTRL [Config.c, 156] OneSegCfg_LoadConfigFile
#   E/...   : SDtvTunerDriver.c L[830] SDtvOneSegTunerDataCB : ...
#
# That is a running commentary on the exact stack this project has to
# reproduce - obtained with no compiler, no dlopen, and no custom kernel. Open
# the stock TV app, drive it, and read what it says.
#
# Usage:
#
#   ./tools/oneseg-logcat.sh                 follow live (Ctrl-C to stop)
#   ./tools/oneseg-logcat.sh -o run.log      also save to a file
#   ./tools/oneseg-logcat.sh -s run.log      summarise a saved capture
#
# SPDX-License-Identifier: Apache-2.0

set -u

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_cyn=$'\033[36m'; c_off=$'\033[0m'

# The tags the 1seg stack logs under, from a real capture.
#   OneSeg            native middleware (DMX / CTRL subsystems)
#   MobileTV          the app's native side
#   MtvOneSegService  Java service
#   MtvAppPlayerOneSeg / MtvUiLivePlayer   Java UI and player
#   SDtv*             tuner driver wrapper
#   DEBUG / libc      crashes, if anything falls over
PATTERN='OneSeg|MobileTV|Mtv[A-Za-z]*|SDtv|isdbt|ISDBT|nmi326|DEBUG|libc *\('

usage() {
    echo "usage: $0 [-o OUTFILE] [-s LOGFILE]"
    echo
    echo "  -o OUTFILE   follow live and also write to OUTFILE"
    echo "  -s LOGFILE   do not capture; summarise a file captured earlier"
    echo
    echo "With no options, follows live until Ctrl-C."
}

summarise() {
    local f="$1"
    [ -f "$f" ] || { echo "no such file: $f" >&2; return 1; }

    echo
    echo "=== summary of $f ==="
    echo

    # 1. Signal. This is usually the answer when nothing plays.
    echo "${c_cyn}signal${c_off}"
    if grep -qi 'Low- *Signal\|Low Signal\|good signal area' "$f"; then
        printf '%sNO SIGNAL%s - the stack is running but receiving nothing.\n' "$c_red" "$c_off"
        echo "  Extend the rod antenna fully. Try near a window or outdoors."
        echo "  A 1seg antenna indoors on a 2012 handset is genuinely marginal."
    elif grep -qi 'signal' "$f"; then
        grep -i 'signal' "$f" | tail -5 | sed 's/^/  /'
    else
        echo "  (nothing about signal in this capture)"
    fi
    echo

    # 2. Did any data actually move?
    echo "${c_cyn}data flow${c_off}"
    local polls zero
    polls=$(grep -c 'After Polling' "$f" 2>/dev/null || echo 0)
    zero=$(grep 'After Polling' "$f" 2>/dev/null | grep -c 'retval=\[0\]' || echo 0)
    if [ "$polls" -gt 0 ]; then
        echo "  poll() calls seen : $polls"
        echo "  returned nothing  : $zero"
        if [ "$polls" = "$zero" ]; then
            printf '  %severy poll came back empty%s - no TS reached userspace\n' "$c_yel" "$c_off"
        else
            printf '  %ssome polls returned data%s - the tuner produced TS\n' "$c_grn" "$c_off"
            grep 'After Polling' "$f" | grep -v 'retval=\[0\]' | head -5 | sed 's/^/    /'
        fi
    else
        echo "  (no polling lines - was the TV app actually open?)"
    fi
    echo

    # 3. Which source files the stack talks from. This is the map of the
    #    middleware, and it is free.
    echo "${c_cyn}components heard from${c_off}"
    # Two shapes appear in the log:
    #   "[DriverWrap, 396]" / "[  Config.c, 156]"   OneSeg middleware
    #   "SDtvTunerDriver.c  L[830]"                 SDtv layer
    {
        grep -oE '\[ *[A-Za-z0-9_.]+ *, *[0-9]+\]' "$f" 2>/dev/null \
            | tr -d '[]' | sed 's/ *,.*//; s/^ *//'
        grep -oE '[A-Za-z0-9_]+\.c+ +L?\[[0-9]+\]' "$f" 2>/dev/null \
            | sed 's/ .*//'
    } | grep -vE '^[0-9]*$' | sort | uniq -c | sort -rn | head -20 | sed 's/^/  /' 
    echo

    # 4. Errors, which name the failing function directly.
    echo "${c_cyn}errors${c_off}"
    grep -E '^E/|ERROR|Cannot|cannot|invalid|fail' "$f" 2>/dev/null \
        | sed 's/.*): //' | sort | uniq -c | sort -rn | head -15 | sed 's/^/  /'
    echo

    # 5. Files the stack wanted and did not find - these may need to exist in
    #    a port.
    echo "${c_cyn}files it looked for${c_off}"
    grep -oE '/(data|system|sdcard|efs)/[A-Za-z0-9_./-]+' "$f" 2>/dev/null \
        | sort -u | head -20 | sed 's/^/  /'
    echo

    echo "Full capture is in $f - the interesting part is the ordering of the"
    echo "calls, which is the tuning sequence this project has to reproduce."
}

# ---------------------------------------------------------------------------

OUT=""
SUM=""
while getopts "o:s:h" opt; do
    case "$opt" in
        o) OUT="$OPTARG" ;;
        s) SUM="$OPTARG" ;;
        *) usage; [ "$opt" = h ] && exit 0 || exit 2 ;;
    esac
done

if [ -n "$SUM" ]; then
    summarise "$SUM"
    exit $?
fi

command -v adb >/dev/null 2>&1 || { echo "adb not found in PATH" >&2; exit 1; }
state="$(adb get-state 2>/dev/null | tr -d '\r')"
[ "$state" = "device" ] || { echo "no device (state: ${state:-none})" >&2; exit 1; }

echo "clearing the log ..."
adb logcat -c 2>/dev/null

cat <<'EOF'

Now, on the phone:

  1. EXTEND THE ROD ANTENNA fully. This matters more than anything else
     here - the stack cannot show you a tuning sequence it never completes.
  2. Open the stock TV app (ワンセグ / MobileTV).
  3. Run a channel scan, then select a channel.
  4. Let it sit for a few seconds whether or not a picture appears.

Ctrl-C here when done.

EOF

# Ctrl-C is the normal way to end a capture, so it must not skip the summary.
# With a trap installed, bash runs the handler and carries on to the next
# command instead of tearing the script down with the pipeline.
trap 'echo; echo "(capture stopped)"' INT

if [ -n "$OUT" ]; then
    echo "following, and saving to $OUT ..."
    echo
    adb logcat -v time 2>/dev/null | grep --line-buffered -E "$PATTERN" | tee "$OUT"
    summarise "$OUT"
else
    echo "following (use -o FILE to keep a copy and get a summary) ..."
    echo
    adb logcat -v time 2>/dev/null | grep --line-buffered -E "$PATTERN"
    echo
    echo "Nothing was saved. Re-run with -o run.log to keep the capture and"
    echo "get a summary of it."
fi
