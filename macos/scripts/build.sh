#!/bin/bash
# CI build: xcodegen -> xcodebuild -> sign -> notarize -> staple -> zip.
# Requires: APPLE_ID, APPLE_APP_PASSWORD, APPLE_TEAM_ID, SIGNING_CERT_BASE64,
# SIGNING_CERT_PASSWORD in the environment.
set -euo pipefail

VERSION="${VERSION:-1.0.0}"
cd "$(dirname "$0")/.."

xcodegen generate

# Import the Developer ID cert into a throwaway keychain (CI only —
# locally the identity already lives in the login keychain)
if [ -n "${SIGNING_CERT_BASE64:-}" ]; then
    echo "$SIGNING_CERT_BASE64" | base64 -d > /tmp/cert.p12
    security create-keychain -p tempkeychain build.keychain || true
    security set-keychain-settings -lut 21600 build.keychain
    security unlock-keychain -p tempkeychain build.keychain
    security import /tmp/cert.p12 -k build.keychain -P "$SIGNING_CERT_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
    security set-key-partition-list -S apple-tool:,apple: -s -k tempkeychain build.keychain
    existing_keychains=()
    while IFS= read -r kc; do
        kc="${kc#"${kc%%[![:space:]]*}"}"
        kc="${kc%\"}"
        kc="${kc#\"}"
        base="${kc##*/}"
        if [ -n "$kc" ] && [ "$base" != "build.keychain" ] && [ "$base" != "build.keychain-db" ]; then
            existing_keychains+=("$kc")
        fi
    done < <(security list-keychains -d user)
    security list-keychains -d user -s build.keychain "${existing_keychains[@]}"
    security default-keychain -s build.keychain

    cleanup() {
        rm -f /tmp/cert.p12
        security delete-keychain build.keychain || true
    }
    trap cleanup EXIT
fi

rm -rf build/Talkist.xcarchive build/export "build/Talkist_${VERSION}_arm64.zip"

# Build + archive + export with the Developer ID identity
xcodebuild -project Talkist.xcodeproj -scheme Talkist -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath build/DerivedData \
    MARKETING_VERSION="$VERSION" \
    CODE_SIGN_IDENTITY="Developer ID Application: Daniel Delaney (367XU828P7)" \
    DEVELOPMENT_TEAM=367XU828P7 \
    CODE_SIGN_STYLE=Manual \
    archive -archivePath build/Talkist.xcarchive

xcodebuild -exportArchive -archivePath build/Talkist.xcarchive \
    -exportOptionsPlist export-options.plist -exportPath build/export

APP=build/export/Talkist.app
codesign --verify --deep --strict --verbose=2 "$APP"

actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [ "$actual_version" != "$VERSION" ]; then
    echo "Expected CFBundleShortVersionString=$VERSION, got $actual_version" >&2
    exit 1
fi

ZIP="build/Talkist_${VERSION}_arm64.zip"

# Zip first: notarytool takes a zip/dmg/pkg, not a bare .app bundle
ditto -c -k --keepParent "$APP" "$ZIP"

# Notarize: keychain profile when available (local), env creds otherwise (CI)
if [ -n "${APPLE_ID:-}" ]; then
    xcrun notarytool submit "$ZIP" \
        --apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$APPLE_TEAM_ID" --wait
else
    xcrun notarytool submit "$ZIP" --keychain-profile "${NOTARY_PROFILE:-talkist}" --wait
fi
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl -a -vvv "$APP"

# Re-zip the stapled .app so the published archive includes the notarization ticket
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
