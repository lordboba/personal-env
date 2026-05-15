#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Personal Env"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
INFO_PLIST="$APP_DIR/Contents/Info.plist"
DOWNLOAD_DMG="$ROOT_DIR/download-site/public/downloads/Personal-Env-macOS.dmg"
APPCAST_PATH="${PERSONAL_ENV_APPCAST_PATH:-$ROOT_DIR/download-site/public/appcast.xml}"
BASE_URL="${PERSONAL_ENV_DOWNLOAD_BASE_URL:-https://personal-env.vercel.app}"
DOWNLOAD_URL="${PERSONAL_ENV_APPCAST_DOWNLOAD_URL:-$BASE_URL/downloads/Personal-Env-macOS.dmg}"
PRIVATE_KEY_FILE="${PERSONAL_ENV_SPARKLE_PRIVATE_KEY_FILE:-}"
SIGN_UPDATE="${PERSONAL_ENV_SPARKLE_SIGN_UPDATE:-}"

if [[ ! -f "$DOWNLOAD_DMG" ]]; then
  echo "Missing DMG at $DOWNLOAD_DMG. Run scripts/package-macos.sh first." >&2
  exit 1
fi

if [[ ! -f "$INFO_PLIST" ]]; then
  echo "Missing app bundle at $APP_DIR. Run scripts/package-macos.sh first." >&2
  exit 1
fi

if [[ -z "$SIGN_UPDATE" ]]; then
  SIGN_UPDATE="$(find "$ROOT_DIR/.build" -path '*/Sparkle/bin/sign_update' -type f -perm -111 2>/dev/null | head -n 1 || true)"
fi

if [[ -z "$SIGN_UPDATE" || ! -x "$SIGN_UPDATE" ]]; then
  echo "Could not find Sparkle sign_update. Build or resolve the Swift package, or set PERSONAL_ENV_SPARKLE_SIGN_UPDATE." >&2
  exit 1
fi

sign_args=("$DOWNLOAD_DMG")
if [[ -n "$PRIVATE_KEY_FILE" ]]; then
  if [[ ! -f "$PRIVATE_KEY_FILE" ]]; then
    echo "Missing Sparkle private key file at $PRIVATE_KEY_FILE." >&2
    exit 1
  fi
  sign_args+=("--ed-key-file" "$PRIVATE_KEY_FILE")
fi

signature_fragment="$("$SIGN_UPDATE" "${sign_args[@]}")"
if [[ "$signature_fragment" != *"sparkle:edSignature="* || "$signature_fragment" != *"length="* ]]; then
  echo "Sparkle sign_update did not produce an EdDSA signature and length." >&2
  echo "$signature_fragment" >&2
  exit 1
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
pub_date="$(LC_ALL=C date -Ru)"

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  value="${value//\'/&apos;}"
  printf '%s' "$value"
}

mkdir -p "$(dirname "$APPCAST_PATH")"
cat > "$APPCAST_PATH" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Personal Env Updates</title>
    <link>$(xml_escape "$BASE_URL")</link>
    <description>Stable releases for Personal Env.</description>
    <language>en</language>
    <item>
      <title>Version $(xml_escape "$version")</title>
      <pubDate>$(xml_escape "$pub_date")</pubDate>
      <sparkle:version>$(xml_escape "$build")</sparkle:version>
      <sparkle:shortVersionString>$(xml_escape "$version")</sparkle:shortVersionString>
      <enclosure url="$(xml_escape "$DOWNLOAD_URL")" type="application/octet-stream" $signature_fragment />
    </item>
  </channel>
</rss>
XML

echo "$APPCAST_PATH"
