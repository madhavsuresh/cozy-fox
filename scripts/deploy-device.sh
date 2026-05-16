#!/usr/bin/env bash
# Build CozyFox (Debug) and install on a connected iPhone.
# Usage: scripts/deploy-device.sh [UDID]
#   With no UDID, picks the single connected device. Errors if 0 or multiple.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

command -v xcodegen >/dev/null || { echo "Install xcodegen first: brew install xcodegen" >&2; exit 1; }

echo "→ Regenerating CozyFox.xcodeproj"
xcodegen generate >/dev/null

if [ "${1:-}" != "" ]; then
  udid="$1"
else
  udids=()
  while IFS= read -r line; do
    udids+=("$line")
  done < <(xcrun devicectl list devices 2>/dev/null | awk '$1 == "iPhone" && $4 == "connected" {print $3}')
  case "${#udids[@]}" in
    0) echo "No connected iPhone. Plug one in (or pair over Wi-Fi) and re-run." >&2; exit 1 ;;
    1) udid="${udids[0]}" ;;
    *) echo "Multiple connected iPhones — pass a UDID:" >&2
       printf '  %s\n' "${udids[@]}" >&2
       exit 1 ;;
  esac
fi
echo "→ Targeting $udid"

echo "→ Building (Debug, iOS device)"
xcodebuild \
  -scheme CozyFox \
  -project CozyFox.xcodeproj \
  -destination "platform=iOS,id=$udid" \
  -configuration Debug \
  -derivedDataPath ./build \
  build

app="./build/Build/Products/Debug-iphoneos/CozyFox.app"
[ -d "$app" ] || { echo "Build product missing: $app" >&2; exit 1; }

echo "→ Installing $app"
xcrun devicectl device install app --device "$udid" "$app"
echo "✓ Installed. Launch Cozy Fox from the home screen."
