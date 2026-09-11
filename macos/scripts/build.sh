#!/bin/bash
# CI build: xcodegen -> xcodebuild -> sign -> notarize -> staple -> zip.
# Requires: APPLE_ID, APPLE_APP_PASSWORD, APPLE_TEAM_ID, SIGNING_CERT_BASE64,
# SIGNING_CERT_PASSWORD in the environment.
set -euo pipefail

VERSION="${VERSION:-0.1.4}"
cd "$(dirname "$0")/.."

xcodegen generate

# Import the Developer ID cert into a throwaway keychain (CI only —
# locally the identity already lives in the login keychain)
if [ -n "${SIGNING_CERT_BASE64:-}" ]; then
    echo "$SIGNING_CERT_BASE64" | base64 -d > /tmp/cert.p12
    security create-keychain -p tempkeychain build.keychain || true
    security import /tmp/cert.p12 -k build.keychain -P "$SIGNING_CERT_PASSWORD" -T /usr/bin/codesign
    security set-key-partition-list -S apple-tool:,apple: -s -k tempkeychain build.keychain
    security list-keychains -d user -s build.keychain "$(security list-keychains -d user | sed 's/"//g' | grep -v build.keychain | tr '\n' ' ')"

    cleanup() {
        rm -f /tmp/cert.p12
        security delete-keychain build.keychain || true
    }
    trap cleanup EXIT
fi

# Build + archive + export with the Developer ID identity
xcodebuild -project Talkist.xcodeproj -scheme Talkist -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath build/DerivedData \
    CODE_SIGN_IDENTITY="Developer ID Application: Daniel Delaney (367XU828P7)" \
    DEVELOPMENT_TEAM=367XU828P7 \
    CODE_SIGN_STYLE=Manual \
    archive -archivePath build/Talkist.xcarchive

cat > /tmp/export-options.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>367XU828P7</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath build/Talkist.xcarchive \
    -exportOptionsPlist /tmp/export-options.plist -exportPath build/export

APP=build/export/Talkist.app
codesign --verify --verbose "$APP"

# Zip first: notarytool takes a zip/dmg/pkg, not a bare .app bundle
cd build/export
ditto -c -k --keepParent Talkist.app "../../Talkist_${VERSION}_arm64.zip"
cd ../..

# Notarize: keychain profile when available (local), env creds otherwise (CI)
if [ -n "${APPLE_ID:-}" ]; then
    xcrun notarytool submit "build/Talkist_${VERSION}_arm64.zip" \
        --apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$APPLE_TEAM_ID" --wait
else
    xcrun notarytool submit "build/Talkist_${VERSION}_arm64.zip" --keychain-profile "${NOTARY_PROFILE:-talkist}" --wait
fi
xcrun stapler staple "$APP"
codesign --verify --verbose "$APP"