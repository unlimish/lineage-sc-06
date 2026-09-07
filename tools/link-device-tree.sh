#!/bin/bash
#
# link-device-tree.sh - hook device/samsung/d2dcm from this repository into a
# synced LineageOS tree.
#
#   ./tools/link-device-tree.sh /path/to/lineage
#
# repo cannot map a subdirectory of one git repository onto a path inside
# another, so the d2dcm tree is symlinked rather than synced. Editing it here
# and rebuilding there then works with no copying step in between.
#
# SPDX-License-Identifier: Apache-2.0

set -eu

MY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$MY_DIR/device/samsung/d2dcm"

if [ $# -ne 1 ]; then
    echo "usage: $0 <LINEAGE_ROOT>" >&2
    exit 2
fi

ROOT="$1"

[ -d "$SRC" ] || { echo "error: $SRC not found - is this repo intact?" >&2; exit 1; }
[ -d "$ROOT" ] || { echo "error: $ROOT does not exist" >&2; exit 1; }

# Refuse to treat this repository as the Lineage tree. Running repo init inside
# it nests hundreds of git repositories in a git repository, which is a mess to
# unpick - so catch the mistake at the point it becomes visible.
ROOT_ABS="$(cd "$ROOT" && pwd)"
case "$ROOT_ABS" in
    "$MY_DIR"|"$MY_DIR"/*)
        echo "error: $ROOT is inside this project repository." >&2
        echo >&2
        echo "The LineageOS tree belongs somewhere else entirely - repo init" >&2
        echo "unpacks .repo/ and hundreds of git repositories, and nesting" >&2
        echo "that inside $MY_DIR leaves both unusable." >&2
        echo >&2
        echo "  mkdir -p ~/lineage && cd ~/lineage" >&2
        echo "  repo init -u https://github.com/LineageOS/android.git \\" >&2
        echo "      -b lineage-16.0 --depth=1 --no-clone-bundle" >&2
        echo >&2
        echo "then run this again with that directory." >&2
        exit 1 ;;
esac

[ -d "$ROOT/.repo" ] || {
    echo "error: $ROOT has no .repo/ - it is not a synced repo tree." >&2
    echo "       Run repo init and repo sync there first; see docs/03." >&2
    exit 1
}

if [ ! -d "$ROOT/device/samsung/d2att" ]; then
    echo "error: $ROOT/device/samsung/d2att is missing." >&2
    echo "       d2dcm inherits from it. Install manifests/local_manifest.xml as" >&2
    echo "       $ROOT/.repo/local_manifests/d2dcm.xml and run 'repo sync' first." >&2
    exit 1
fi

DEST="$ROOT/device/samsung/d2dcm"

if [ -L "$DEST" ]; then
    cur="$(readlink "$DEST")"
    if [ "$cur" = "$SRC" ]; then
        echo "already linked: $DEST -> $SRC"
        exit 0
    fi
    echo "error: $DEST is a symlink to something else:" >&2
    echo "       $cur" >&2
    echo "       Remove it yourself if that is stale - refusing to guess." >&2
    exit 1
elif [ -e "$DEST" ]; then
    echo "error: $DEST already exists and is not a symlink." >&2
    echo "       Refusing to overwrite a real directory. Move it aside first." >&2
    exit 1
fi

mkdir -p "$(dirname "$DEST")"
ln -s "$SRC" "$DEST"
echo "linked: $DEST -> $SRC"
echo
echo "next:"
echo "  cd $ROOT"
echo "  source build/envsetup.sh"
echo "  lunch lineage_d2dcm-userdebug"
