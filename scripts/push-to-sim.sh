#!/bin/sh
# Copies a folder (or file) into the booted simulator's Files app ("On My iPad").
# Usage: scripts/push-to-sim.sh [path]     (default: ~/Documents/books)
set -e

SRC="${1:-$HOME/Documents/books}"
UDID=$(xcrun simctl getenv booted SIMULATOR_UDID) || {
    echo "No booted simulator." >&2
    exit 1
}

DEST=""
for d in "$HOME/Library/Developer/CoreSimulator/Devices/$UDID/data/Containers/Shared/AppGroup"/*/; do
    id=$(plutil -extract MCMMetadataIdentifier raw "$d/.com.apple.mobile_container_manager.metadata.plist" 2>/dev/null) || continue
    if [ "$id" = "group.com.apple.FileProvider.LocalStorage" ]; then
        DEST="$d/File Provider Storage"
        break
    fi
done

if [ -z "$DEST" ]; then
    echo "Local storage not found — open the Files app in the simulator once, then retry." >&2
    exit 1
fi

cp -R "$SRC" "$DEST/"
echo "Copied $(basename "$SRC") -> Files > On My iPad ($UDID)"
