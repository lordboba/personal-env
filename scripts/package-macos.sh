#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Personal Env"
EXECUTABLE_NAME="PersonalEnv"
BUILD_DIR="$ROOT_DIR/.build/release"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
DOWNLOADS_DIR="$ROOT_DIR/download-site/public/downloads"
DOWNLOAD_DMG="$DOWNLOADS_DIR/Personal-Env-macOS.dmg"
STALE_DOWNLOAD_ZIP="$DOWNLOADS_DIR/Personal-Env-macOS.zip"
STANDALONE_DOWNLOADS_DIR="$ROOT_DIR/download-site/.next/standalone/public/downloads"
DMG_STAGING_DIR="$ROOT_DIR/dist/dmg"
DMG_BACKGROUND_DIR="$DMG_STAGING_DIR/.background"
DMG_BACKGROUND="$DMG_BACKGROUND_DIR/background.png"
DMG_RW="$ROOT_DIR/dist/Personal-Env-macOS-rw.dmg"
ICONSET_DIR="$ROOT_DIR/dist/PersonalEnv.iconset"
APP_ICON="$RESOURCES_DIR/PersonalEnv.icns"
SIGN_IDENTITY="${PERSONAL_ENV_SIGN_IDENTITY:-}"
NOTARIZE="${PERSONAL_ENV_NOTARIZE:-0}"
APP_VERSION="${PERSONAL_ENV_VERSION:-0.1.0}"
APP_BUILD="${PERSONAL_ENV_BUILD:-1}"
SPARKLE_FEED_URL="${PERSONAL_ENV_SPARKLE_FEED_URL:-https://personal-env.vercel.app/appcast.xml}"
SPARKLE_PUBLIC_KEY="${PERSONAL_ENV_SPARKLE_PUBLIC_KEY:-}"
APPLE_ID="${PERSONAL_ENV_APPLE_ID:-}"
APPLE_TEAM_ID="${PERSONAL_ENV_APPLE_TEAM_ID:-}"
APPLE_APP_PASSWORD="${PERSONAL_ENV_APPLE_APP_PASSWORD:-}"
APPLY_DMG_LAYOUT="${PERSONAL_ENV_APPLY_DMG_LAYOUT:-1}"

require_notarization_config() {
  if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "PERSONAL_ENV_SIGN_IDENTITY is required when PERSONAL_ENV_NOTARIZE=1" >&2
    exit 1
  fi
  if [[ -z "$APPLE_ID" || -z "$APPLE_TEAM_ID" || -z "$APPLE_APP_PASSWORD" ]]; then
    echo "PERSONAL_ENV_APPLE_ID, PERSONAL_ENV_APPLE_TEAM_ID, and PERSONAL_ENV_APPLE_APP_PASSWORD are required when PERSONAL_ENV_NOTARIZE=1" >&2
    exit 1
  fi
  if [[ -z "$SPARKLE_PUBLIC_KEY" ]]; then
    echo "PERSONAL_ENV_SPARKLE_PUBLIC_KEY is required when PERSONAL_ENV_NOTARIZE=1" >&2
    exit 1
  fi
}

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  value="${value//\'/&apos;}"
  printf '%s' "$value"
}

sign_app() {
  if [[ -n "$SIGN_IDENTITY" ]]; then
    codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_DIR"
  else
    codesign --force --deep --sign - "$APP_DIR"
  fi
}

sign_dmg() {
  if [[ -n "$SIGN_IDENTITY" ]]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DOWNLOAD_DMG"
  fi
}

notarize_dmg() {
  xcrun notarytool submit "$DOWNLOAD_DMG" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait
  xcrun stapler staple "$DOWNLOAD_DMG"
}

verify_artifacts() {
  codesign --verify --deep --strict --verbose=2 "$APP_DIR"
  if [[ -n "$SIGN_IDENTITY" ]]; then
    codesign --verify --verbose=2 "$DOWNLOAD_DMG"
  fi
  if [[ "$NOTARIZE" == "1" ]]; then
    spctl --assess --type execute --verbose=4 "$APP_DIR"
    spctl --assess --type open --context context:primary-signature --verbose=4 "$DOWNLOAD_DMG"
    xcrun stapler validate "$DOWNLOAD_DMG"
  fi
}

if [[ "$NOTARIZE" == "1" ]]; then
  require_notarization_config
fi

cd "$ROOT_DIR"
if [[ -n "$SPARKLE_PUBLIC_KEY" ]]; then
  PERSONAL_ENV_ENABLE_SPARKLE_UPDATES=1 swift build -c release --product "$EXECUTABLE_NAME"
else
  swift build -c release --product "$EXECUTABLE_NAME"
fi

rm -rf "$APP_DIR" "$DMG_STAGING_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"
cp "$BUILD_DIR/$EXECUTABLE_NAME" "$MACOS_DIR/$EXECUTABLE_NAME"
chmod +x "$MACOS_DIR/$EXECUTABLE_NAME"

SPARKLE_FRAMEWORK="$(find "$ROOT_DIR/.build" -path '*/Sparkle.framework' -type d 2>/dev/null | head -n 1 || true)"
if [[ -n "$SPARKLE_FRAMEWORK" ]]; then
  cp -R "$SPARKLE_FRAMEWORK" "$FRAMEWORKS_DIR/"
elif [[ -n "$SPARKLE_PUBLIC_KEY" ]]; then
  echo "Sparkle.framework was not found under .build after release build." >&2
  exit 1
fi

rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"
cp "$ROOT_DIR"/Sources/PersonalEnvApp/Assets.xcassets/AppIcon.appiconset/icon_*.png "$ICONSET_DIR/"
iconutil -c icns "$ICONSET_DIR" -o "$APP_ICON"
rm -rf "$ICONSET_DIR"

if [[ -f "$ROOT_DIR/Assets/personal-env-ui-reference.png" ]]; then
  cp "$ROOT_DIR/Assets/personal-env-ui-reference.png" "$RESOURCES_DIR/personal-env-ui-reference.png"
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>PersonalEnv</string>
  <key>CFBundleIdentifier</key>
  <string>com.tylerxiao.personal-env</string>
  <key>CFBundleIconFile</key>
  <string>PersonalEnv</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Personal Env</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$(xml_escape "$APP_VERSION")</string>
  <key>CFBundleVersion</key>
  <string>$(xml_escape "$APP_BUILD")</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright 2026 Tyler Xiao</string>
</dict>
</plist>
PLIST

if [[ -n "$SPARKLE_PUBLIC_KEY" ]]; then
  /usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool true" "$CONTENTS_DIR/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $SPARKLE_FEED_URL" "$CONTENTS_DIR/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_KEY" "$CONTENTS_DIR/Info.plist"
fi

sign_app

mkdir -p "$DOWNLOADS_DIR" "$DMG_STAGING_DIR"
cp -R "$APP_DIR" "$DMG_STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$DMG_STAGING_DIR/Applications"
rm -f "$DOWNLOAD_DMG" "$STALE_DOWNLOAD_ZIP"

if [[ "$APPLY_DMG_LAYOUT" == "1" ]]; then
  mkdir -p "$DMG_BACKGROUND_DIR"
  python3 - "$DMG_BACKGROUND" <<'PY'
from PIL import Image, ImageDraw, ImageFont
import sys

out = sys.argv[1]
w, h = 1072, 686
img = Image.new("RGB", (w, h), "#0b1630")
draw = ImageDraw.Draw(img, "RGBA")
draw.polygon([(0, 150), (w, 400), (w, 475), (0, 590)], fill="#26337d")
draw.polygon([(0, 335), (w, 475), (w, 405), (0, 150)], fill="#293789")

def rounded_rect(x, y, width, height):
    draw.rounded_rectangle((x, y, x + width, y + height), radius=38, fill=(250, 250, 250, 255))

rounded_rect(100, 230, 292, 292)
rounded_rect(680, 230, 292, 292)

# Applications drop target hint.
dash = (215, 215, 215, 255)
draw.rounded_rectangle((735, 260, 925, 450), radius=32, outline=dash, width=5)
for x in range(765, 900, 30):
    draw.line((x, 260, x + 16, 260), fill=(250, 250, 250, 255), width=7)
    draw.line((x, 450, x + 16, 450), fill=(250, 250, 250, 255), width=7)
for y in range(295, 425, 30):
    draw.line((735, y, 735, y + 16), fill=(250, 250, 250, 255), width=7)
    draw.line((925, y, 925, y + 16), fill=(250, 250, 250, 255), width=7)
img.save(out)
PY
fi

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGING_DIR" \
  -ov \
  -format UDRW \
  "$DMG_RW"

if [[ "$APPLY_DMG_LAYOUT" == "1" ]]; then
  ATTACH_OUTPUT="$(hdiutil attach "$DMG_RW" -readwrite -noverify -noautoopen)"
  DEVICE="$(awk '/\/Volumes\/Personal Env/ {device=$1} END {print device}' <<<"$ATTACH_OUTPUT")"
  if [[ -z "$DEVICE" ]]; then
    echo "$ATTACH_OUTPUT" >&2
    echo "Failed to find attached DMG device for $APP_NAME." >&2
    exit 1
  fi
  VOLUME="/Volumes/$APP_NAME"
  if [[ ! -d "$VOLUME" ]]; then
    VOLUME="$(awk '/\/Volumes\/Personal Env/ {for (i=3; i<=NF; i++) path = path (i == 3 ? "" : " ") $i} END {print path}' <<<"$ATTACH_OUTPUT")"
  fi
  sleep 2
  osascript <<OSA
tell application "Finder"
  tell disk "$APP_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {160, 120, 1232, 806}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 144
    set background picture of theViewOptions to (POSIX file "$VOLUME/.background/background.png" as alias)
    set position of item "$APP_NAME.app" of container window to {246, 360}
    set position of item "Applications" of container window to {826, 360}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
  hdiutil detach "$DEVICE"
fi
hdiutil convert "$DMG_RW" -format UDZO -o "$DOWNLOAD_DMG" -ov
rm -rf "$DMG_STAGING_DIR" "$DMG_RW"
sign_dmg

if [[ "$NOTARIZE" == "1" ]]; then
  notarize_dmg
fi

verify_artifacts

if [[ -d "$ROOT_DIR/download-site/.next/standalone" ]]; then
  mkdir -p "$STANDALONE_DOWNLOADS_DIR"
  cp "$DOWNLOAD_DMG" "$STANDALONE_DOWNLOADS_DIR/$(basename "$DOWNLOAD_DMG")"
  rm -f "$STANDALONE_DOWNLOADS_DIR/$(basename "$STALE_DOWNLOAD_ZIP")"
fi

echo "$APP_DIR"
echo "$DOWNLOAD_DMG"
