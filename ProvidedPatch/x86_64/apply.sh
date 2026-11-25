#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="${1:-}"

if [ -z "$APP" ]; then
    echo "Usage: $0 /path/to/World of Warcraft.app" >&2
    echo "   or: $0 /path/to/_midnight_" >&2
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
DYLIB="$ROOT/libFirestormCertBypassX86.dylib"

if pgrep -f "World of Warcraft.app/Contents/MacOS/World of Warcraft" >/dev/null 2>&1; then
    echo "World of Warcraft appears to be running. Quit it before applying." >&2
    exit 1
fi

[ -f "$BIN" ] || { echo "Missing executable: $BIN" >&2; exit 1; }
[ -f "$DYLIB" ] || { echo "Missing dylib: $DYLIB" >&2; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$APP/../World of Warcraft.backup-$STAMP"
cp -p "$BIN" "$BACKUP"
echo "Backup: $BACKUP"

cp -p "$DYLIB" "$APP/Contents/MacOS/libFirestormCertBypassX86.dylib"
codesign --force --sign - "$APP/Contents/MacOS/libFirestormCertBypassX86.dylib"

python3 "$ROOT/add_dependency_x86_64.py" "$BIN" "@executable_path/libFirestormCertBypassX86.dylib"

codesign --force --sign - --options runtime --entitlements "$ROOT/Entitlements.plist" "$APP"
codesign --verify --deep --strict "$APP"

echo "Patched: $APP"
echo "Patch log: /tmp/FirestormCertBypassX86.log"
