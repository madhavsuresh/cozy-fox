#!/usr/bin/env bash
# Build CozyFox (Debug) and install on a reachable iPhone.
# Usage: scripts/deploy-device.sh [UDID]
#   With no UDID, picks the single reachable device (USB or Wi-Fi-paired).
#   Errors if 0 or multiple.
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
  done < <(xcrun devicectl list devices 2>/dev/null | awk '$1 == "iPhone" && ($4 == "connected" || $4 == "available") {print $3}')
  case "${#udids[@]}" in
    0) echo "No reachable iPhone. Plug one in or pair over Wi-Fi (Xcode → Window → Devices) and re-run." >&2
       echo "Current devicectl view:" >&2
       xcrun devicectl list devices 2>/dev/null >&2
       exit 1 ;;
    1) udid="${udids[0]}" ;;
    *) echo "Multiple reachable iPhones — pass a UDID:" >&2
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
