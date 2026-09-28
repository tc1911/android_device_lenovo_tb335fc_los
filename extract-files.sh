#!/bin/bash
# Extract vendor blobs for Lenovo TB335FC (sycamore) from a mounted stock system
# Usage: ./extract-files.sh [device] [vendor_root]
#   device: adb device serial (optional)
#   vendor_root: path to a mounted stock system (optional, defaults to adb pull)

set -e
VENDOR_ROOT=""
DEVICE=""

if [ $# -ge 1 ]; then
    DEVICE="$1"
fi
if [ $# -ge 2 ]; then
    VENDOR_ROOT="$2"
fi

PROPRIETARY_FILES="$(dirname "$0")/proprietary-files.txt"
OUT_DIR="$(dirname "$0")/../../../vendor/lenovo/sycamore"
mkdir -p "$OUT_DIR"

echo "Extracting proprietary blobs to $OUT_DIR"

while IFS= read -r line; do
    # Skip comments and empty lines
    [[ "$line" =~ ^#.*$ ]] && continue
    [[ -z "$line" ]] && continue

    # Handle "|" alternates and "-" prefixes
    src="${line#-}"
    src="${src%%|*}"
    src="${src# }"

    # Skip non-vendor paths (odm etc handled below)
    if [[ "$src" == vendor/* ]]; then
        target="${src#vendor/}"
        src_path="/vendor/$target"
        dest="$OUT_DIR/vendor/$target"
    elif [[ "$src" == odm/* ]]; then
        target="${src#odm/}"
        src_path="/odm/$target"
        dest="$OUT_DIR/odm/$target"
    else
        continue
    fi

    mkdir -p "$(dirname "$dest")"
    if [ -n "$VENDOR_ROOT" ]; then
        # Copy from a mounted filesystem
        if [ -f "$VENDOR_ROOT$src_path" ]; then
            cp "$VENDOR_ROOT$src_path" "$dest"
        else
            echo "WARNING: $src_path not found"
        fi
    else
        # Pull via adb
        adb -s "$DEVICE" pull "$src_path" "$dest" 2>/dev/null || \
            echo "WARNING: $src_path not found on device"
    fi
done < "$PROPRIETARY_FILES"

echo "Done. Blobs extracted to $OUT_DIR"
