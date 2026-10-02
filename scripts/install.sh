#!/bin/sh
# Build WatchMan (Release), signed by Xcode with the team's certificate (so macOS keeps its permissions across
# updates, and iCloud and push work), install it in /Applications and restart it if it was running.
#
#   scripts/install.sh
set -e
cd "$(dirname "$0")/.."

APP=build.noindex/Build/Products/Release/WatchMan.app

xcodegen -q
# Xcode signs it with the team's certificate and a profile that allows iCloud and push (creating them if needed)
xcodebuild -project WatchMan.xcodeproj -scheme WatchMan -configuration Release -derivedDataPath build.noindex \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration build \
    | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
codesign --verify --deep --strict "$APP"
echo "signed: $(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"

RUNNING=$(pgrep -x WatchMan || true)
if [ -n "$RUNNING" ]; then
    osascript -e 'quit app "WatchMan"'
    sleep 1
fi
ditto "$APP" /Applications/WatchMan.app
echo "installed /Applications/WatchMan.app"
if [ -n "$RUNNING" ]; then
    open -a /Applications/WatchMan.app
    echo "restarted"
fi
