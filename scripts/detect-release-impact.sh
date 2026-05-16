#!/usr/bin/env bash
set -euo pipefail

release_impacting_path() {
  local path="$1"

  case "$path" in
    .github/workflows/notarized-dmg.yml|\
    Package.swift|\
    Package.resolved|\
    Assets/*|\
    PersonalEnv.xcodeproj/*|\
    Sources/*|\
    Tests/*|\
    scripts/detect-release-impact.sh|\
    scripts/generate-appcast.sh|\
    scripts/package-macos.sh)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

changed=false

while IFS= read -r path; do
  if [[ -z "$path" ]]; then
    continue
  fi

  if release_impacting_path "$path"; then
    changed=true
    break
  fi
done

printf '%s\n' "$changed"
