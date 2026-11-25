#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="${1:-}"

if [ -z "$APP" ]; then
    echo "Usage: $0 /path/to/World of Warcraft.app" >&2
    exit 1
fi

if [ -d "$APP/Contents/MacOS" ]; then
    :
elif [ -d "$APP/_midnight_/World of Warcraft.app" ]; then
    APP="$APP/_midnight_/World of Warcraft.app"
elif [ -d "$APP/World of Warcraft.app" ]; then
    APP="$APP/World of Warcraft.app"
else
    echo "Not a World of Warcraft.app bundle: $APP" >&2
    exit 1
fi

BIN="$APP/Contents/MacOS/World of Warcraft"
BACKUP="$(ls -t "$APP/../World of Warcraft.backup-"* 2>/dev/null | head -1 || true)"

if [ -z "$BACKUP" ]; then
    echo "No backup found next to $APP" >&2
    exit 1
fi

cp -p "$BACKUP" "$BIN"
rm -f "$APP/Contents/MacOS/libFirestormCertBypassX86.dylib"
codesign --force --sign - --options runtime --entitlements "$ROOT/Entitlements.plist" "$APP"
codesign --verify --deep --strict "$APP"

echo "Restored: $BACKUP"
echo "Reverted: $APP"
