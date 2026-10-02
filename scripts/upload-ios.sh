#!/bin/sh
# Archives WatchMan for iPhone and uploads it to App Store Connect (for TestFlight and the App Store), signed by
# Xcode with the account it's signed in to (Xcode → Settings → Accounts).
#
#   scripts/upload-ios.sh
#
# Each upload needs a higher build number: raise CFBundleVersion for the iPhone targets in project.yml first.
set -e
cd "$(dirname "$0")/.."

TEAM=${TEAM:-ZMQ73447P3}
DIST=dist/ios
ARCHIVE="$DIST/WatchManPhone.xcarchive"

rm -rf "$DIST" && mkdir -p "$DIST"
cat > "$DIST/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>upload</string>
    <key>signingStyle</key><string>automatic</string>
    <key>teamID</key><string>$TEAM</string>
    <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
EOF

xcodegen -q
echo "archiving WatchMan for iPhone…"
xcodebuild archive -project WatchMan.xcodeproj -scheme WatchManPhone -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" -derivedDataPath build.noindex/ios-release DEVELOPMENT_TEAM="$TEAM" -allowProvisioningUpdates \
    | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)"

echo "uploading to App Store Connect…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$DIST/ExportOptions.plist" \
    -exportPath "$DIST/upload" -allowProvisioningUpdates > "$DIST/export.log" 2>&1 || true
grep -E "error:|EXPORT (SUCCEEDED|FAILED)" "$DIST/export.log" || true
grep -q "EXPORT SUCCEEDED" "$DIST/export.log" || { echo "the upload failed: see $DIST/export.log"; exit 1; }
echo "uploaded: it shows in App Store Connect → TestFlight after Apple processes it (about 10–30 minutes)"
