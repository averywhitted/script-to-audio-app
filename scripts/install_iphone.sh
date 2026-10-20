#!/bin/bash
# Builds Table Read for iPhone and installs it on the iPhone plugged into this
# Mac (or on the same Wi-Fi). Free Apple accounts sign apps for 7 days: rerun
# this weekly.
#
#   bash scripts/install_iphone.sh            # first connected iPhone
#   bash scripts/install_iphone.sh <udid>     # a specific one
#
# Needs: Xcode signed in to Avery's Apple ID (Xcode → Settings → Accounts),
# the iPhone in Developer Mode, and the developer trusted on the phone
# (Settings → General → VPN & Device Management) after the first install.

set -euo pipefail
cd "$(dirname "$0")/../app"

udid="${1:-}"
if [ -z "$udid" ]; then
    udid=$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && /physical/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) print $i }' | head -1)
fi
if [ -z "$udid" ]; then
    echo "No iPhone found. Plug it in (and unlock it), then try again." >&2
    exit 1
fi
echo "iPhone: $udid"

flutter build ios --release --no-codesign
# The device id lets Xcode register the phone and make a profile for it.
if ! xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Release \
    -destination "id=$udid" -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    -derivedDataPath build/ios-device build 2>&1 | tee build/ios-device-build.log | grep -E "error:|\*\* BUILD"; then
    :
fi
if ! grep -q "BUILD SUCCEEDED" build/ios-device-build.log; then
    if grep -q "No Accounts" build/ios-device-build.log; then
        echo "Xcode isn't signed in: open Xcode → Settings → Accounts and sign in to your Apple ID." >&2
    fi
    exit 1
fi

xcrun devicectl device install app --device "$udid" build/ios-device/Build/Products/Release-iphoneos/Runner.app
echo "✓ Installed. Open Table Read on the iPhone."
