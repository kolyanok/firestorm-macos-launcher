#!/bin/bash
set -euo pipefail

project="$(cd "$(dirname "$0")" && pwd -P)"
output="${1:-$project/dist}"
mkdir -p "$output"
output="$(cd "$output" && pwd -P)"
stage="$(mktemp -d "$output/.firestorm-build.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
release="$stage/Firestorm-Launcher"
app="$release/Firestorm Launcher.app"
cache="${TMPDIR:-/tmp}/firestorm-launcher-swift-cache"
payload="${FIRESTORM_CLIENT_PAYLOAD_DIR:-$project/Resources}"
if [[ -z "${FIRESTORM_CLIENT_PAYLOAD_DIR:-}" && ! -s "$payload/Client.zip" ]]; then
  payload="$project/../Firestorm Launcher.app/Contents/Resources"
fi

if [[ ! -s "$payload/Client.zip" || ! -s "$payload/client-manifest.json" ]]; then
  echo "Missing local client payload. Set FIRESTORM_CLIENT_PAYLOAD_DIR to a directory containing Client.zip and client-manifest.json." >&2
  exit 1
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$cache"
xcrun swift -module-cache-path "$cache" "$project/make_icon.swift" "$stage/Firestorm.iconset"
cp "$stage/Firestorm.icns" "$app/Contents/Resources/Firestorm.icns"
xcrun swiftc -parse-as-library -target arm64-apple-macos14.0 -swift-version 5 -O \
  -module-cache-path "$cache" "$project"/Sources/*.swift \
  -o "$app/Contents/MacOS/FirestormLauncher"
cp "$project/Info.plist" "$app/Contents/Info.plist"
cp "$payload/Client.zip" "$payload/client-manifest.json" "$app/Contents/Resources/"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
cp "$project/README.md" "$release/README.md"
cp "$project/LICENSE" "$release/LICENSE"
cp "$project/THIRD_PARTY_NOTICES.md" "$release/THIRD_PARTY_NOTICES.md"
source="$release/Source"
mkdir -p "$source/Sources" "$source/Tests" "$source/Resources"
cp "$project"/Sources/*.swift "$source/Sources/"
cp "$project/Tests/CoreTests.swift" "$source/Tests/"
cp "$project/test.sh" "$project/build.sh" "$project/Info.plist" \
  "$project/make_icon.swift" "$project/README.md" "$project/LICENSE" "$project/THIRD_PARTY_NOTICES.md" "$source/"
cp "$payload/client-manifest.json" "$source/Resources/"
if [[ -d "$project/ProvidedPatch" ]]; then
  ditto "$project/ProvidedPatch" "$source/ProvidedPatch"
fi
ditto -c -k --sequesterRsrc --keepParent "$release" "$stage/Firestorm-Launcher-macOS.zip"
if [[ -e "$output/Firestorm-Launcher" ]]; then
  old="$output/Firestorm-Launcher.previous-$(date +%Y%m%d-%H%M%S)-$$"
  mv "$output/Firestorm-Launcher" "$old"
fi
mv "$release" "$output/Firestorm-Launcher"
mv "$stage/Firestorm-Launcher-macOS.zip" "$output/Firestorm-Launcher-macOS.zip"
echo "Built: $output/Firestorm-Launcher/Firestorm Launcher.app"
echo "Archive: $output/Firestorm-Launcher-macOS.zip"
