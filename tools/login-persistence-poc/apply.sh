#!/bin/bash
set -euo pipefail
POC="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$POC/../.." && pwd)"
APP="$HOME/Library/Containers/io.playcover.PlayCover/Applications/jp.co.bandainamcoent.BNEI0421.app"
BIN="$APP/idolmaster_gakuen"
BACKUP="$POC/private-backup/idolmaster_gakuen.before-compat"
if [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist")" != '3.4.0' ] ||
   [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist")" != '89' ]; then
  echo 'This PoC is scoped to Gakumas 3.4.0 build 89.' >&2; exit 1
fi
if /usr/bin/pgrep -x idolmaster_gakuen >/dev/null; then
  echo 'Quit the game before applying the PoC.' >&2; exit 1
fi
test -f "$POC/build/GakuPlayChainCompat.dylib"
test -f "$BIN.orig"
test -x "$ROOT/tools/insert_dylib"
if [ ! -f "$BACKUP" ]; then
  if otool -L "$BIN" | grep -Fq 'GakuPlayChainCompat'; then
    echo 'PoC already installed from another location; use its original rollback script.' >&2; exit 1
  fi
  umask 077
  mkdir -p "$POC/private-backup"
  chmod 700 "$POC/private-backup"
  codesign -d --entitlements - --xml "$BIN" > "$POC/private-backup/entitlements.plist" 2>/dev/null
  cp -p "$BIN" "$BACKUP"
  chmod 600 "$BACKUP"
fi
test -s "$POC/private-backup/entitlements.plist"
cp "$POC/build/GakuPlayChainCompat.dylib" "$APP/Frameworks/GakuPlayChainCompat.dylib"
codesign --force --sign - "$APP/Frameworks/GakuPlayChainCompat.dylib"
if ! otool -L "$BIN" | grep -Fq 'GakuPlayChainCompat'; then
  "$ROOT/tools/insert_dylib" --inplace --all-yes '@rpath/GakuPlayChainCompat.dylib' "$BIN"
fi
codesign --force --sign - --entitlements "$POC/private-backup/entitlements.plist" "$BIN"
codesign --force --sign - --entitlements "$POC/private-backup/entitlements.plist" "$APP"
codesign --verify --verbose "$APP"
echo 'Game-local PoC applied. Launch with make run.'
