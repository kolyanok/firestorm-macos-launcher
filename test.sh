#!/bin/bash
set -euo pipefail
project="$(cd "$(dirname "$0")" && pwd)"
build="$project/.test-build"
architecture="${FIRESTORM_TEST_ARCH:-$(uname -m)}"
case "$architecture" in
  arm64|x86_64) ;;
  *) echo "Unsupported test architecture: $architecture" >&2; exit 1 ;;
esac
mkdir -p "$build" "${TMPDIR:-/tmp}/firestorm-launcher-test-cache"
xcrun swiftc -parse-as-library -swift-version 5 -target "$architecture-apple-macos14.0" \
  -module-cache-path "${TMPDIR:-/tmp}/firestorm-launcher-test-cache" \
  "$project/Sources/Localization.swift" "$project/Sources/InterfaceTranslations.swift" "$project/Sources/CoreTranslations.swift" \
  "$project/Sources/LauncherCore.swift" "$project/Sources/CASCStorage.swift" "$project/Tests/CoreTests.swift" \
  -o "$build/CoreTests-$architecture"
/usr/bin/arch "-$architecture" "$build/CoreTests-$architecture"
