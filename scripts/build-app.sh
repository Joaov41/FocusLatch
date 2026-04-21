#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/FocusLatch.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
PLIST_PATH="$CONTENTS_DIR/Info.plist"
ICON_SOURCE_PATH="$ROOT_DIR/assets/focus-latch-logo-v1.png"
ICONSET_DIR="$ROOT_DIR/dist/FocusLatch.iconset"
ICON_FILE_NAME="FocusLatch.icns"
BUNDLE_ID="${BUNDLE_ID:-com.codex.focuslatch.downloads}"
SIGNING_MODE="${SIGNING_MODE:-development}"
APP_VERSION="${APP_VERSION:-0.1.0}"
APP_BUILD="${APP_BUILD:-1}"
ENTITLEMENTS_PATH="${ENTITLEMENTS_PATH:-}"

case "$SIGNING_MODE" in
    development)
        DEFAULT_SIGNING_IDENTITY="Apple Development: Joao Valente (NJ46KD28PD)"
        CODESIGN_FLAGS=()
        ;;
    developer-id)
        DEFAULT_SIGNING_IDENTITY="Developer ID Application: Joao Valente (HNG8WV554B)"
        CODESIGN_FLAGS=(--options runtime --timestamp)
        ;;
    unsigned)
        DEFAULT_SIGNING_IDENTITY=""
        CODESIGN_FLAGS=()
        ;;
    *)
        echo "Unsupported SIGNING_MODE: $SIGNING_MODE" >&2
        echo "Expected one of: development, developer-id, unsigned" >&2
        exit 1
        ;;
esac

SIGNING_IDENTITY="${SIGNING_IDENTITY:-$DEFAULT_SIGNING_IDENTITY}"

swift build -c release --product FocusLatch

BINARY_DIR="$(swift build -c release --show-bin-path)"
BINARY_PATH="$BINARY_DIR/FocusLatch"

rm -rf "$APP_DIR"
rm -rf "$ICONSET_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$ICONSET_DIR"

cp "$BINARY_PATH" "$MACOS_DIR/FocusLatch"

if [[ ! -f "$ICON_SOURCE_PATH" ]]; then
    echo "Missing app icon source at $ICON_SOURCE_PATH" >&2
    exit 1
fi

for spec in \
    "16 icon_16x16.png" \
    "32 icon_16x16@2x.png" \
    "32 icon_32x32.png" \
    "64 icon_32x32@2x.png" \
    "128 icon_128x128.png" \
    "256 icon_128x128@2x.png" \
    "256 icon_256x256.png" \
    "512 icon_256x256@2x.png" \
    "512 icon_512x512.png" \
    "1024 icon_512x512@2x.png"
do
    read -r size filename <<<"$spec"
    sips -z "$size" "$size" "$ICON_SOURCE_PATH" --out "$ICONSET_DIR/$filename" >/dev/null
done

iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/$ICON_FILE_NAME"

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>Focus Latch</string>
    <key>CFBundleExecutable</key>
    <string>FocusLatch</string>
    <key>CFBundleIconFile</key>
    <string>${ICON_FILE_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>FocusLatch</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${APP_BUILD}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Focus Latch needs Screen Recording permission to pin and preview other app windows.</string>
</dict>
</plist>
PLIST

rm -rf "$CONTENTS_DIR/_CodeSignature"
codesign --remove-signature "$APP_DIR" 2>/dev/null || true

if [[ -n "$SIGNING_IDENTITY" ]]; then
    if ! security find-identity -v -p codesigning | grep -Fq "$SIGNING_IDENTITY"; then
        echo "Signing identity not installed in the local keychain: $SIGNING_IDENTITY" >&2
        exit 1
    fi

    CODESIGN_COMMAND=(
        codesign
        --force
        --sign "$SIGNING_IDENTITY"
        --identifier "$BUNDLE_ID"
    )

    if [[ -n "$ENTITLEMENTS_PATH" ]]; then
        CODESIGN_COMMAND+=(--entitlements "$ENTITLEMENTS_PATH")
    fi

    CODESIGN_COMMAND+=("${CODESIGN_FLAGS[@]}" "$APP_DIR")
    "${CODESIGN_COMMAND[@]}"
else
    echo "Skipping code signing because SIGNING_MODE=unsigned"
fi

rm -rf "$ICONSET_DIR"

echo "Built $APP_DIR"
