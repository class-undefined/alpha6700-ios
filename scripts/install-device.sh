#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE_ID="${1:-${DEVICE_ID:-}}"
if [ -z "$DEVICE_ID" ]; then
  DEVICE_LIST="$(mktemp)"
  trap 'rm -f "$DEVICE_LIST"' EXIT
  xcrun devicectl list devices --json-output "$DEVICE_LIST" >/dev/null
  DEVICE_ID="$(/usr/bin/python3 - "$DEVICE_LIST" <<'PY'
import json,sys
items=json.load(open(sys.argv[1])).get('result',{}).get('devices',[])
items=[d for d in items if d.get('hardwareProperties',{}).get('platform')=='iOS' and d.get('connectionProperties',{}).get('pairingState')=='paired']
if len(items)!=1:
    sys.exit('Pass the device identifier as argument 1; found %d paired iOS devices.' % len(items))
print(items[0]['identifier'])
PY
)"
fi
if [ ! -f "$TASK_ROOT/ios/Local.xcconfig" ]; then
  echo 'Select your Personal Team in Xcode, or create ios/Local.xcconfig containing DEVELOPMENT_TEAM = YOUR_TEAM_ID.' >&2
  exit 2
fi
mkdir -p "$TASK_ROOT/build"
xcodebuild -project "$TASK_ROOT/ios/AlphaRemote.xcodeproj" -scheme AlphaRemote \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath "$TASK_ROOT/build/DeviceData" -allowProvisioningUpdates build \
  > "$TASK_ROOT/build/device-build.log" 2>&1 || {
    tail -60 "$TASK_ROOT/build/device-build.log" >&2; exit 1;
  }
APP_PATH="$TASK_ROOT/build/DeviceData/Build/Products/Debug-iphoneos/AlphaRemote.app"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" \
  --json-output "$TASK_ROOT/build/install-result.json"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP_PATH/Info.plist")
xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID"
/usr/bin/python3 "$TASK_ROOT/scripts/profile-expiry.py" "$APP_PATH"
