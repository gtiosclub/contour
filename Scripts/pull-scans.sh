#!/bin/bash
#
# pull-scans.sh — copy the scans a debug build saved on an iPhone to this Mac.
#
# Debug builds keep the photo and result of every scan in the app's
# Documents/Scans (ContourApp/ContourApp/Debug/ScanArchive.swift). This copies
# them into one folder the real-frames scoreboard can read as it is.
#
# USAGE
#   Scripts/pull-scans.sh [bundle-id] [device] [destination]
#
#   bundle-id    The app's bundle id. Default: the one app named ContourApp on
#                the phone. Pass "" to keep the default and give a device.
#   device       UDID or name, as `xcrun devicectl list devices` shows them.
#                Default: the one iPhone on a cable, else the only one reachable.
#   destination  Default: ~/Downloads/Contour scans <date and time>.
#
# The phone has to be unlocked. Delete the saved scans in the app's Developer
# tools once they're copied.

set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
bundle=${1:-}
device=${2:-}
destination=${3:-"$HOME/Downloads/Contour scans $(date +%Y-%m-%d-%H%M)"}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# devicectl's JSON is the stable output; the tables can change between Xcodes.
value() { plutil -extract "$1" raw -o - "$2"; }

score() {
    cat <<EOF
Score them on this Mac (it runs every photo through the scanner again):
  CONTOUR_FRAMES_DIR="$1" swift test --package-path "$repo/Packages/SurfaceUnderstanding" --filter realFramesScoreboard
EOF
}

# Xcode's own way to the same files, for when devicectl can't copy them.
use_xcode() {
    cat >&2 <<EOF

Copy them with Xcode instead: Window > Devices and Simulators, pick the iPhone,
select ContourApp under Installed Apps, then Download Container from its menu.
The scans are inside the downloaded container, in AppData/Documents/Scans.
EOF
    score "<the downloaded container>.xcappdata/AppData/Documents/Scans" >&2
    exit 1
}

if [[ -z $device ]]; then
    phones="properties.hardware.reality = 'physical' AND properties.hardware.platform = 'iOS'"
    for filter in "$phones AND properties.connection.transportType = 'wired'" \
                  "$phones AND properties.connection.transportType != nil"; do
        xcrun devicectl list devices --filter "$filter" --quiet --json-output "$work/devices.json"
        count=$(value result.devices "$work/devices.json")
        if [[ $count == 1 ]]; then
            device=$(value result.devices.0.properties.hardware.udid "$work/devices.json")
            break
        elif (( count > 1 )); then
            echo "More than one iPhone is connected. Pass the one to use as the second argument:" >&2
            xcrun devicectl list devices --filter "$filter" >&2
            exit 1
        fi
    done
    if [[ -z $device ]]; then
        echo "No iPhone found. Plug it in, unlock it and try again." >&2
        exit 1
    fi
fi

if [[ -z $bundle ]]; then
    xcrun devicectl device info apps --device "$device" --filter "name = 'ContourApp'" \
        --quiet --json-output "$work/apps.json"
    count=$(value result.apps "$work/apps.json")
    if [[ $count != 1 ]]; then
        echo "Found $count apps named ContourApp on $device. Pass the bundle id as the first argument:" >&2
        xcrun devicectl device info apps --device "$device" --filter "name = 'ContourApp'" >&2
        exit 1
    fi
    bundle=$(value result.apps.0.bundleIdentifier "$work/apps.json")
fi

# The user on an iPhone is always "mobile". Copies from an app's container
# have been reported to need it.
copy() {
    xcrun devicectl device copy from --device "$device" --user mobile --domain-type appDataContainer \
        --domain-identifier "$bundle" --quiet "$@"
}

mkdir -p "$work/copy"
echo "Copying Documents/Scans of $bundle from $device..."
if ! copy --source Documents/Scans --destination "$work/copy/Scans" --timeout 300; then
    # Copying a whole folder has been reported to time out, while single files
    # copy fine.
    echo "Copying the folder failed. Copying one file at a time instead, which is slower..." >&2
    # Anything the folder copy got before it failed would be counted twice.
    rm -rf "$work/copy" && mkdir -p "$work/copy"
    xcrun devicectl device info files --device "$device" --username mobile --domain-type appDataContainer \
        --domain-identifier "$bundle" --subdirectory Documents/Scans --quiet \
        --json-output "$work/files.json" || use_xcode
    # Only the names are needed, so this doesn't depend on how the listing is laid out.
    names=$(grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}-[0-9]{3}-[0-9]{4,}\.(jpg|json)' "$work/files.json" \
        | sort -u || true)
    total=$(echo "$names" | grep -c . || true)
    if [[ $total == 0 ]]; then
        echo "No saved scans on the phone. Has a debug build of the app scanned on it?" >&2
        exit 1
    fi
    tried=0
    for name in $names; do
        copy --source "Documents/Scans/$name" --destination "$work/copy/$name" --timeout 60 \
            || echo "Couldn't copy $name." >&2
        tried=$((tried + 1))
        if (( tried % 50 == 0 )); then echo "$tried of $total files..."; fi
    done
fi

# Wherever devicectl put them, the scoreboard wants NAME.jpg and NAME.json side
# by side in one folder, and stops at a photo without its sidecar.
mkdir -p "$destination"
photos=0
missing=0
while IFS= read -r -d '' photo; do
    if [[ -f ${photo%.jpg}.json ]]; then
        mv -f "$photo" "${photo%.jpg}.json" "$destination/"
        photos=$((photos + 1))
    else
        missing=$((missing + 1))
    fi
done < <(find "$work/copy" -type f -name '*.jpg' -print0)

if [[ $photos == 0 ]]; then
    rmdir "$destination" 2>/dev/null || true
    echo "No saved scans came off the phone. Has a debug build of the app scanned on it?" >&2
    exit 1
fi
if [[ $missing != 0 ]]; then
    echo "Photos left out because their NAME.json didn't copy: $missing" >&2
fi

echo "$photos scans in $destination"
echo
score "$destination"
cat <<EOF

Each NAME.json also has what the phone made of that scan: seconds, error,
fullFrame, keypadFound, canGuide and buttons (labels with boxes in the photo).
EOF
