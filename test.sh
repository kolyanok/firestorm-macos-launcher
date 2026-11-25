#!/bin/bash
set -euo pipefail
project="$(cd "$(dirname "$0")" && pwd)"
build="$project/.test-build"
mkdir -p "$build" "${TMPDIR:-/tmp}/firestorm-launcher-test-cache"
xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos14.0 \
  -module-cache-path "${TMPDIR:-/tmp}/firestorm-launcher-test-cache" \
  "$project/Sources/LauncherCore.swift" "$project/Sources/CASCStorage.swift" "$project/Tests/CoreTests.swift" \
  -o "$build/CoreTests"
"$build/CoreTests"
