#!/usr/bin/env bash
# Builds dist/RtlTerminal.app (and a .zip and .dmg) on macOS.
#   ./scripts/build-app.sh            build for this Mac's architecture
#   UNIVERSAL=1 ./scripts/build-app.sh  Apple Silicon + Intel (needs Xcode)
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="$(tr -d '[:space:]' < VERSION)"
APP="dist/RtlTerminal.app"

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
else
    ARCH_FLAGS=()
fi

swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/RtlTerminal" "$APP/Contents/MacOS/RtlTerminal"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# App icon from the 256 px PNG.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256; do
    sips -z "$size" "$size" Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

# Ad-hoc signature: required to run on Apple Silicon. Set SIGN_IDENTITY
# to a "Developer ID Application" identity for distribution.
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
    codesign --force --deep --sign - "$APP"
fi

(cd dist && rm -f "RtlTerminal-$VERSION-macOS.zip" && ditto -c -k --keepParent RtlTerminal.app "RtlTerminal-$VERSION-macOS.zip")

STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "dist/RtlTerminal-$VERSION-macOS.dmg"
hdiutil create -volname "Rtl Terminal" -srcfolder "$STAGING" -ov -format UDZO "dist/RtlTerminal-$VERSION-macOS.dmg" >/dev/null
rm -rf "$STAGING"

echo "Built $APP"
echo "      dist/RtlTerminal-$VERSION-macOS.zip"
echo "      dist/RtlTerminal-$VERSION-macOS.dmg"
