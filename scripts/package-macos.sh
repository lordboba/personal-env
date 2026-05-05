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
DOWNLOADS_DIR="$ROOT_DIR/download-site/public/downloads"
DOWNLOAD_ZIP="$DOWNLOADS_DIR/Personal-Env-macOS.zip"

cd "$ROOT_DIR"
swift build -c release --product "$EXECUTABLE_NAME"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BUILD_DIR/$EXECUTABLE_NAME" "$MACOS_DIR/$EXECUTABLE_NAME"
chmod +x "$MACOS_DIR/$EXECUTABLE_NAME"

if [[ -f "$ROOT_DIR/Assets/personal-env-ui-reference.png" ]]; then
  cp "$ROOT_DIR/Assets/personal-env-ui-reference.png" "$RESOURCES_DIR/personal-env-ui-reference.png"
fi

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
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
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Personal Env</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright 2026 Tyler Xiao</string>
</dict>
</plist>
PLIST

mkdir -p "$DOWNLOADS_DIR"
ditto -c -k --norsrc --noextattr --keepParent "$APP_DIR" "$DOWNLOAD_ZIP"

echo "$APP_DIR"
echo "$DOWNLOAD_ZIP"
