#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Notchi Release Script
# Usage: ./scripts/create-release.sh <version>
# Example: ./scripts/create-release.sh 1.1.0
# =============================================================================

# --- Configuration ---
TEAM_ID="SXT98GH5HN"
BUNDLE_ID="com.ruban.notchi"
SCHEME="notchi"
PROJECT_PATH="notchi/notchi.xcodeproj"
APPCAST_OUTPUT="docs/appcast.xml"
APP_NAME="Notchi"
WEBSITE_APPCAST_OUTPUT="website/public/appcast.xml"
SIGNED_RELEASE_NOTES_DIR="website/release-notes-signed"

# TODO: Set your notarytool keychain profile name.
# Create one with: xcrun notarytool store-credentials "notchi-notarize" --apple-id "you@example.com" --team-id "SXT98GH5HN"
NOTARYTOOL_PROFILE="notchi-notarize"

# Sparkle tools directory — override with SPARKLE_BIN_DIR env var.
# Falls back to searching DerivedData for the Sparkle build artifacts.
SPARKLE_BIN_DIR="${SPARKLE_BIN_DIR:-}"

BUILD_DIR="build/release"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
APP_PATH="${EXPORT_DIR}/${APP_NAME}.app"
XCODEBUILD_LOG="${BUILD_DIR}/xcodebuild.log"

# --- Helpers ---
step() {
    echo ""
    echo "===> $1"
    echo ""
}

fail() {
    echo "ERROR: $1" >&2
    exit 1
}

find_sparkle_bin_dir() {
    if [[ -n "$SPARKLE_BIN_DIR" ]]; then
        echo "$SPARKLE_BIN_DIR"
        return
    fi

    local derived_data="${HOME}/Library/Developer/Xcode/DerivedData"
    local found
    found=$(find "$derived_data" -path "*/SourcePackages/artifacts/sparkle/Sparkle/bin" -type d 2>/dev/null | head -n 1)

    if [[ -z "$found" ]]; then
        found=$(find "$derived_data" -name "sign_update" -type f 2>/dev/null | head -n 1)
        if [[ -n "$found" ]]; then
            found=$(dirname "$found")
        fi
    fi

    if [[ -z "$found" ]]; then
        fail "Could not find Sparkle tools. Set SPARKLE_BIN_DIR to the directory containing sign_update and generate_appcast."
    fi

    echo "$found"
}

read_build_setting() {
    local key="$1"

    xcodebuild -showBuildSettings \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        2>/dev/null | awk -F' = ' -v key="$key" '{ name = $1; sub(/^[[:space:]]+/, "", name) } name == key { print $2; exit }'
}

# Pipe through xcpretty only when it's installed; pipefail keeps xcodebuild's exit status.
# The raw log is kept because xcpretty hides the details of a failure.
run_xcodebuild() {
    if command -v xcpretty >/dev/null 2>&1; then
        xcodebuild "$@" | tee -a "$XCODEBUILD_LOG" | xcpretty
    else
        xcodebuild "$@"
    fi
}

read_latest_published_build_version() {
    if [[ ! -f "$APPCAST_OUTPUT" ]]; then
        return 0
    fi

    grep -oE '<sparkle:version>[0-9]+' "$APPCAST_OUTPUT" 2>/dev/null | sed 's#<sparkle:version>##' | head -n 1 || true
}

# --- Step 1: Validate version argument ---
VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    fail "Usage: $0 <version>  (e.g. $0 1.1.0)"
fi

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail "Version must be in semver format (e.g. 1.1.0), got: $VERSION"
fi

DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_PATH="${BUILD_DIR}/${DMG_NAME}"
DMG_SHA256_PATH="${BUILD_DIR}/${APP_NAME}-${VERSION}.sha256"
RELEASE_NOTES_SOURCE="docs/release-notes/${VERSION}.md"
RELEASE_NOTES_ASSET="${BUILD_DIR}/${APP_NAME}-${VERSION}.md"

step "Starting release build for ${APP_NAME} v${VERSION}"

if [[ ! -f "$RELEASE_NOTES_SOURCE" ]]; then
    fail "Missing release notes file at ${RELEASE_NOTES_SOURCE}"
fi

MARKETING_VERSION="$(read_build_setting "MARKETING_VERSION")"
BUILD_VERSION="$(read_build_setting "CURRENT_PROJECT_VERSION")"

if [[ -z "$MARKETING_VERSION" ]]; then
    fail "Could not determine MARKETING_VERSION from ${PROJECT_PATH}"
fi

if [[ -z "$BUILD_VERSION" ]]; then
    fail "Could not determine CURRENT_PROJECT_VERSION from ${PROJECT_PATH}"
fi

if [[ "$MARKETING_VERSION" != "$VERSION" ]]; then
    fail "Requested version ${VERSION} does not match project MARKETING_VERSION ${MARKETING_VERSION}"
fi

if ! [[ "$BUILD_VERSION" =~ ^[0-9]+$ ]]; then
    fail "CURRENT_PROJECT_VERSION must be numeric, got: ${BUILD_VERSION}"
fi

LAST_PUBLISHED_BUILD="$(read_latest_published_build_version)"

if [[ -n "$LAST_PUBLISHED_BUILD" ]]; then
    if ! [[ "$LAST_PUBLISHED_BUILD" =~ ^[0-9]+$ ]]; then
        fail "Latest published sparkle:version must be numeric, got: ${LAST_PUBLISHED_BUILD}"
    fi

    if (( BUILD_VERSION <= LAST_PUBLISHED_BUILD )); then
        fail "CURRENT_PROJECT_VERSION ${BUILD_VERSION} must be greater than latest published sparkle:version ${LAST_PUBLISHED_BUILD}"
    fi

    echo "Validated project version ${MARKETING_VERSION} (build ${BUILD_VERSION}) against published build ${LAST_PUBLISHED_BUILD}"
else
    echo "Validated project version ${MARKETING_VERSION} (build ${BUILD_VERSION}) in bootstrap mode with no published appcast item"
fi

# --- Step 2: Clean and archive ---
step "Step 1/6: Clean and archive (Developer ID distribution)"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

run_xcodebuild clean archive \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE="Manual"

echo "Archive created at ${ARCHIVE_PATH}"

# --- Step 3: Export the archive ---
step "Step 2/6: Export archive"

EXPORT_OPTIONS_PLIST="${BUILD_DIR}/ExportOptions.plist"
cat > "$EXPORT_OPTIONS_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
</dict>
</plist>
PLIST

run_xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
    -exportPath "$EXPORT_DIR"

if [[ ! -d "$APP_PATH" ]]; then
    fail "Export failed: ${APP_PATH} not found"
fi

echo "Exported ${APP_PATH}"

# --- Step 4: Notarize and staple ---
step "Step 3/6: Notarize and staple"

NOTARIZE_ZIP="${BUILD_DIR}/notchi-submit.zip"
echo "Creating zip for notarization..."
ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"

echo "Submitting for notarization..."
xcrun notarytool submit "$NOTARIZE_ZIP" \
    --keychain-profile "$NOTARYTOOL_PROFILE" \
    --wait

rm -f "$NOTARIZE_ZIP"

echo "Stapling notarization ticket..."
xcrun stapler staple "$APP_PATH"

echo "Notarization complete and stapled into ${APP_PATH}"

# --- Step 5: Create DMG ---
step "Step 4/6: Create distribution DMG"

DMG_TEMP_DIR="${BUILD_DIR}/dmg-staging"
rm -rf "$DMG_TEMP_DIR"
mkdir -p "$DMG_TEMP_DIR"

cp -R "$APP_PATH" "$DMG_TEMP_DIR/"
ln -s /Applications "$DMG_TEMP_DIR/Applications"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_TEMP_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

rm -rf "$DMG_TEMP_DIR"

if [[ ! -f "$DMG_PATH" ]]; then
    fail "DMG creation failed: ${DMG_PATH} not found"
fi

echo "Created ${DMG_PATH}"

DMG_SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
printf '%s\n' "$DMG_SHA256" > "$DMG_SHA256_PATH"
echo "DMG SHA-256:"
echo "$DMG_SHA256"
echo "Checksum written to ${DMG_SHA256_PATH}"

cp "$RELEASE_NOTES_SOURCE" "$RELEASE_NOTES_ASSET"
echo "Prepared release notes asset at ${RELEASE_NOTES_ASSET}"

# --- Step 6: Sign with Sparkle ---
step "Step 5/6: Sign DMG with Sparkle"

SPARKLE_KEY_FILE=".sparkle-keys/eddsa_private_key"
if [[ ! -f "$SPARKLE_KEY_FILE" ]]; then
    fail "Sparkle private key not found at ${SPARKLE_KEY_FILE}. Run generate_keys and save the key there."
fi

SPARKLE_BIN_DIR=$(find_sparkle_bin_dir)
SIGN_UPDATE="${SPARKLE_BIN_DIR}/sign_update"
GENERATE_APPCAST="${SPARKLE_BIN_DIR}/generate_appcast"

if [[ ! -x "$SIGN_UPDATE" ]]; then
    fail "sign_update not found or not executable at ${SIGN_UPDATE}"
fi

if [[ ! -x "$GENERATE_APPCAST" ]]; then
    fail "generate_appcast not found or not executable at ${GENERATE_APPCAST}"
fi

echo "Using Sparkle tools from: ${SPARKLE_BIN_DIR}"

SIGNATURE=$("$SIGN_UPDATE" --ed-key-file "$SPARKLE_KEY_FILE" "$DMG_PATH")
echo "Sparkle signature:"
echo "$SIGNATURE"

# --- Step 7: Generate appcast ---
step "Step 6/6: Generate appcast"

mkdir -p "$(dirname "$APPCAST_OUTPUT")"

APPCAST_STAGING="${BUILD_DIR}/appcast-staging"
rm -rf "$APPCAST_STAGING"
mkdir -p "$APPCAST_STAGING"
cp "$DMG_PATH" "$APPCAST_STAGING/"
cp "$RELEASE_NOTES_ASSET" "$APPCAST_STAGING/"
cp "$APPCAST_OUTPUT" "$APPCAST_STAGING/" 2>/dev/null || true

"$GENERATE_APPCAST" \
    --ed-key-file "$SPARKLE_KEY_FILE" \
    --download-url-prefix "https://github.com/sk-ruban/notchi/releases/download/v${VERSION}/" \
    --release-notes-url-prefix "https://updates.notchi.app/sparkle-notes/" \
    -o "$APPCAST_OUTPUT" \
    "$APPCAST_STAGING"

mkdir -p "$SIGNED_RELEASE_NOTES_DIR"
cp "$APPCAST_STAGING/${APP_NAME}-${VERSION}.md" \
    "$SIGNED_RELEASE_NOTES_DIR/${APP_NAME}-${VERSION}.md"

rm -rf "$APPCAST_STAGING"

mkdir -p "$(dirname "$WEBSITE_APPCAST_OUTPUT")"
cp "$APPCAST_OUTPUT" "$WEBSITE_APPCAST_OUTPUT"

echo "Appcast written to ${APPCAST_OUTPUT}"
echo "Website appcast synced to ${WEBSITE_APPCAST_OUTPUT}"

# --- Done ---
step "Release v${VERSION} built successfully!"

echo "Files:"
echo "  DMG:     ${DMG_PATH}"
echo "  SHA256:  ${DMG_SHA256_PATH}"
echo "  Notes:   ${RELEASE_NOTES_ASSET}"
echo "  Appcast: ${APPCAST_OUTPUT}"
echo ""
echo "Next steps:"
echo "  1. Create a GitHub Release tagged v${VERSION}"
echo "  2. Upload ${DMG_PATH} and ${RELEASE_NOTES_ASSET} to the GitHub Release"
echo "  3. Commit ${APPCAST_OUTPUT} and ${WEBSITE_APPCAST_OUTPUT}, then push to main"
echo "  4. Verify the appcast download URL matches your GitHub Release asset URL"
