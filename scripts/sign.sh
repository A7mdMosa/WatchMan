#!/bin/sh
# Signs a built WatchMan.app: the embedded hook first, then the app, with the hardened runtime.
# Uses the team's Developer ID when this Mac has it, else the old local certificate (no hardened runtime).
#
#   scripts/sign.sh path/to/WatchMan.app [--timestamp]
set -e
APP="$1"
TEAM=${TEAM:-ZMQ73447P3}
DEV_ID=$(security find-identity -v -p codesigning | sed -n "s/.*\"\(Developer ID Application: .* ($TEAM)\)\".*/\1/p" | head -1)
ENTITLEMENTS="$(dirname "$0")/../Config/WatchMan.entitlements"

if [ -n "$DEV_ID" ]; then
    # A secure timestamp is required for notarization; local installs skip it (faster, works offline)
    STAMP="--timestamp=none"
    [ "$2" = "--timestamp" ] && STAMP="--timestamp"
    codesign --force --options runtime $STAMP --sign "$DEV_ID" "$APP/Contents/MacOS/watchman-hook"
    codesign --force --options runtime $STAMP --entitlements "$ENTITLEMENTS" --sign "$DEV_ID" "$APP"
    echo "signed with $DEV_ID"
elif security find-identity -p codesigning | grep -q '"WatchMan Local Signing"'; then
    codesign --force --sign "WatchMan Local Signing" "$APP/Contents/MacOS/watchman-hook"
    codesign --force --sign "WatchMan Local Signing" "$APP"
    echo "signed with WatchMan Local Signing (no Developer ID for team $TEAM on this Mac yet)"
else
    echo "warning: no signing identity; keeping the ad-hoc signature (permissions may reset after updates)"
fi
codesign --verify --deep --strict "$APP"
