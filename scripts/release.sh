#!/bin/sh
# Builds a WatchMan release anyone can download: archived, signed with the team's Developer ID, notarized by Apple
# and stapled, so it opens on any Mac without warnings. Xcode does the signing and the notarization with the account
# it's signed in to (Xcode → Settings → Accounts), so no certificate or password has to be set up by hand.
#
#   scripts/release.sh              # dist/WatchMan-<version>.zip
#   scripts/release.sh --publish    # and publish it: today's files as one new commit on the public repo
#                                   # (without the development history), and a GitHub release there (gh CLI)
#
# Another team: TEAM=XXXXXXXXXX scripts/release.sh (and your own bundle ids and iCloud container in project.yml).
set -e
cd "$(dirname "$0")/.."

TEAM=${TEAM:-ZMQ73447P3}
PUBLIC=${PUBLIC:-A7mdMosa/WatchMan}
if [ "$1" = "--publish" ] && ! git diff --quiet HEAD; then echo "commit your changes first: the release is built from them"; exit 1; fi
VERSION=$(sed -n 's/.*CFBundleShortVersionString: "\(.*\)"/\1/p' project.yml | head -1)
DIST=dist
ARCHIVE="$DIST/WatchMan.xcarchive"
ZIP="$DIST/WatchMan-$VERSION.zip"

rm -rf "$DIST" && mkdir -p "$DIST"
cat > "$DIST/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>destination</key><string>upload</string>
    <key>signingStyle</key><string>automatic</string>
    <key>teamID</key><string>$TEAM</string>
</dict>
</plist>
EOF

echo "archiving WatchMan $VERSION…"
xcodegen -q
xcodebuild archive -project WatchMan.xcodeproj -scheme WatchMan -configuration Release -archivePath "$ARCHIVE" \
    -derivedDataPath build.noindex/release DEVELOPMENT_TEAM="$TEAM" -allowProvisioningUpdates \
    | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)"

echo "signing with Developer ID and sending to Apple's notary service…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$DIST/ExportOptions.plist" \
    -exportPath "$DIST/upload" -allowProvisioningUpdates > "$DIST/export.log" 2>&1 || true
grep -E "error:|EXPORT (SUCCEEDED|FAILED)" "$DIST/export.log" || true
grep -q "EXPORT SUCCEEDED" "$DIST/export.log" || { echo "the upload failed: see $DIST/export.log"; exit 1; }

# Apple usually answers in a few minutes; the notarized app can be exported once it has
echo "waiting for notarization…"
tries=0
until xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$DIST/notarized" >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ $tries -lt 60 ] || { echo "notarization didn't finish in 30 minutes: see Xcode → Window → Organizer"; exit 1; }
    sleep 30
done

APP="$DIST/notarized/WatchMan.app"
spctl --assess --type execute --verbose "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "ready: $ZIP"
shasum -a 256 "$ZIP"

if [ "$1" = "--publish" ]; then
    # The public repo gets one commit per release, on top of its last one
    URL="https://github.com/$PUBLIC.git"
    if git fetch -q "$URL" main 2>/dev/null; then
        COMMIT=$(git commit-tree "HEAD^{tree}" -p FETCH_HEAD -m "WatchMan $VERSION")
    else
        COMMIT=$(git commit-tree "HEAD^{tree}" -m "WatchMan $VERSION")
    fi
    git push -q "$URL" "${COMMIT}:refs/heads/main"
    gh release create "v$VERSION" "$ZIP" --repo "$PUBLIC" --target main --title "WatchMan $VERSION" --generate-notes
fi
