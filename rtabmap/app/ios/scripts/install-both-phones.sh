#!/bin/bash
# Build THIS collab / Rtab-ian RTABMapApp and install it onto Ian's and Weston's iPhones.
# Always uses the dnhacks checkout. Never a stock introlab tree, archive, or other xcodeproj.
#
#   ./app/ios/scripts/install-both-phones.sh
#   ./app/ios/scripts/install-both-phones.sh --dry-run
#
# A missing / unpaired / offline phone is skipped with a clear message.
# Exit 0 if at least one phone was installed (or dry-run listed destinations).
# Exit 1 if no target phone is connected, or every install failed.

set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# Hardcoded collab tree. Relative "find the repo" is how a copied script
# (or a second checkout) can silently build stock RTAB-Map.
CANONICAL_ROOT="/Users/ian/Code/dnhacks/rtabmap"
PROJECT="/Users/ian/Code/dnhacks/rtabmap/app/ios/RTABMapApp.xcodeproj"
COLLAB_MARK="/Users/ian/Code/dnhacks/rtabmap/app/ios/RTABMapApp/CollabSync.swift"
INFO_PLIST="/Users/ian/Code/dnhacks/rtabmap/app/ios/RTABMapApp/Info.plist"
SCHEME="RTABMapApp"
EXPECTED_DISPLAY_NAME="Rtab-ian"
EXPECTED_BUNDLE_ID="com.dnhacks.rtabmap"

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
DEVICES_FILE="$SCRIPT_DIR/devices.txt"
DERIVED="${INSTALL_DERIVED_DATA:-$CANONICAL_ROOT/app/ios/build/DerivedData}"
CONFIGURATION="${INSTALL_CONFIGURATION:-Release}"

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ] || [ "${1:-}" = "-n" ]; then
    DRY_RUN=1
fi

if [ ! -d "$DEVELOPER_DIR" ]; then
    echo "error: Xcode not found at $DEVELOPER_DIR" >&2
    echo "Install Xcode.app or set DEVELOPER_DIR." >&2
    exit 1
fi

case "$SCRIPT_DIR" in
    "$CANONICAL_ROOT"/app/ios/scripts) ;;
    *)
        echo "error: this script must live in the collab tree:" >&2
        echo "  $CANONICAL_ROOT/app/ios/scripts/install-both-phones.sh" >&2
        echo "  (this copy is at $SCRIPT_DIR)" >&2
        exit 1
        ;;
esac

if [ ! -f "$PROJECT/project.pbxproj" ]; then
    echo "error: Xcode project missing: $PROJECT" >&2
    exit 1
fi

if [ ! -f "$COLLAB_MARK" ]; then
    echo "error: CollabSync.swift missing. Refusing to build a non-collab tree." >&2
    echo "  expected: $COLLAB_MARK" >&2
    exit 1
fi

if [ ! -f "$INFO_PLIST" ]; then
    echo "error: Info.plist missing: $INFO_PLIST" >&2
    exit 1
fi

source_display_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$INFO_PLIST" 2>/dev/null || true)"
if [ "$source_display_name" != "$EXPECTED_DISPLAY_NAME" ]; then
    echo "error: source Info.plist display name is '$source_display_name', expected $EXPECTED_DISPLAY_NAME" >&2
    echo "  $INFO_PLIST" >&2
    exit 1
fi

if ! grep -q 'PRODUCT_BUNDLE_IDENTIFIER = com.dnhacks.rtabmap;' "$PROJECT/project.pbxproj"; then
    echo "error: $PROJECT is not bundle $EXPECTED_BUNDLE_ID" >&2
    exit 1
fi

if grep -q 'PRODUCT_BUNDLE_IDENTIFIER = com.dnhacks.rtabmap.stock;' "$PROJECT/project.pbxproj"; then
    echo "error: $PROJECT looks like the stock checkout (com.dnhacks.rtabmap.stock)" >&2
    exit 1
fi

if [ ! -f "$DEVICES_FILE" ]; then
    echo "error: devices file missing: $DEVICES_FILE" >&2
    exit 1
fi

# Returns 0 if UDID is an available (connected) iOS destination.
device_connected() {
    local udid="$1"
    local dests
    dests="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showdestinations 2>/dev/null || true)"
    echo "$dests" | grep -q "platform:iOS, arch:arm64, id:${udid},"
}

verify_built_app() {
    local app="$1"
    local name id settings
    name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$app/Info.plist" 2>/dev/null || true)"
    id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist" 2>/dev/null || true)"
    settings="$app/Settings.bundle/Root.plist"
    echo "Built app: $app"
    echo "  CFBundleDisplayName=$name"
    echo "  CFBundleIdentifier=$id"
    if [ "$name" != "$EXPECTED_DISPLAY_NAME" ]; then
        echo "error: built app home-screen name is '$name', expected $EXPECTED_DISPLAY_NAME" >&2
        echo "This is not the collab / Rtab-ian build. Refusing to install." >&2
        return 1
    fi
    if [ "$id" != "$EXPECTED_BUNDLE_ID" ]; then
        echo "error: built app bundle is '$id', expected $EXPECTED_BUNDLE_ID" >&2
        return 1
    fi
    if [ ! -f "$settings" ] || ! grep -q 'CollabEnabled' "$settings"; then
        echo "error: built app is missing Collaborative Mapping settings (CollabEnabled)" >&2
        return 1
    fi
    echo "  Collab settings: present (CollabEnabled)"
}

echo "===== collab / Rtab-ian identity ====="
echo "Repo:          $CANONICAL_ROOT"
echo "Project:       $PROJECT"
echo "Scheme:        $SCHEME"
echo "Configuration: $CONFIGURATION"
echo "Team:          F38B8K483F (from project; not overridden)"
echo "Bundle:        $EXPECTED_BUNDLE_ID"
echo "Display name:  $source_display_name"
echo "Collab file:   $COLLAB_MARK"
ls -l "$COLLAB_MARK"
echo "Devices:       $DEVICES_FILE"
echo "DerivedData:   $DERIVED"
echo "Xcode:         $DEVELOPER_DIR"
echo

if [ "$DRY_RUN" -eq 1 ]; then
    echo "===== xcodebuild destinations (dry-run) ====="
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showdestinations
    echo
fi

phones=()
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        ''|\#*) continue ;;
    esac
    name="${line%%	*}"
    udid="${line#*	}"
    name="$(printf '%s' "$name" | tr -d '[:space:]')"
    udid="$(printf '%s' "$udid" | tr -d '[:space:]')"
    if [ -z "$name" ] || [ -z "$udid" ]; then
        echo "error: bad devices.txt line: $line" >&2
        exit 1
    fi
    phones+=("$name|$udid")
done < "$DEVICES_FILE"

if [ "${#phones[@]}" -eq 0 ]; then
    echo "error: no phones listed in $DEVICES_FILE" >&2
    exit 1
fi

connected=()
skipped=()
for entry in "${phones[@]}"; do
    name="${entry%%|*}"
    udid="${entry#*|}"
    if [ "$udid" = "REPLACE_ME" ]; then
        skipped+=("$name (UDID unset; run: DEVELOPER_DIR=$DEVELOPER_DIR xcrun xctrace list devices)")
        echo "SKIP $name: no UDID in devices.txt yet."
        continue
    fi
    if device_connected "$udid"; then
        connected+=("$name|$udid")
        echo "OK   $name  id=$udid  (connected)"
    else
        skipped+=("$name ($udid)")
        echo "SKIP $name  id=$udid  (unplugged, unpaired, or offline)"
    fi
done
echo

if [ "$DRY_RUN" -eq 1 ]; then
    if [ "${#connected[@]}" -eq 0 ]; then
        echo "Dry-run: no listed phones are connected. Plug in Ian and/or Weston, trust this Mac, then run without --dry-run."
        exit 1
    fi
    echo "Dry-run: would build+install onto ${#connected[@]} phone(s). Skipped: ${skipped[*]:-none}"
    echo "Full install:"
    echo "  $CANONICAL_ROOT/app/ios/scripts/install-both-phones.sh"
    exit 0
fi

if [ "${#connected[@]}" -eq 0 ]; then
    echo "error: no target phones connected." >&2
    echo "Plug in Ian and/or Weston, unlock, tap Trust, then retry." >&2
    echo "List devices:" >&2
    echo "  DEVELOPER_DIR=$DEVELOPER_DIR xcrun xctrace list devices" >&2
    exit 1
fi

installed=()
failed=()
app=""

for entry in "${connected[@]}"; do
    name="${entry%%|*}"
    udid="${entry#*|}"
    echo "===== $name  destination id=$udid ====="
    echo "xcodebuild -project $PROJECT -scheme $SCHEME -configuration $CONFIGURATION -destination id=$udid"
    if ! xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination "id=$udid" \
        -allowProvisioningUpdates \
        -allowProvisioningDeviceRegistration \
        -derivedDataPath "$DERIVED" \
        build
    then
        echo "error: xcodebuild failed for $name ($udid)" >&2
        failed+=("$name")
        continue
    fi

    app="$DERIVED/Build/Products/${CONFIGURATION}-iphoneos/RTABMapApp.app"
    if [ ! -d "$app" ]; then
        echo "error: built app not found at $app" >&2
        failed+=("$name")
        continue
    fi

    if ! verify_built_app "$app"; then
        failed+=("$name")
        continue
    fi

    if ! xcrun devicectl device install app --device "$udid" "$app"; then
        echo "error: install failed for $name ($udid). Is the phone unlocked and trusted?" >&2
        failed+=("$name")
        continue
    fi
    installed+=("$name")
    echo "Installed $EXPECTED_DISPLAY_NAME ($EXPECTED_BUNDLE_ID, collab) on $name."
    echo
done

echo "===== summary ====="
if [ "${#installed[@]}" -gt 0 ]; then
    echo "Installed: ${installed[*]}"
fi
if [ "${#skipped[@]}" -gt 0 ]; then
    echo "Skipped (not connected): ${skipped[*]}"
fi
if [ "${#failed[@]}" -gt 0 ]; then
    echo "Failed: ${failed[*]}" >&2
fi

if [ "${#installed[@]}" -eq 0 ]; then
    exit 1
fi
exit 0
