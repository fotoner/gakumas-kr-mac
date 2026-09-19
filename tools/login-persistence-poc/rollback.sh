#!/bin/bash
set -euo pipefail
POC="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Library/Containers/io.playcover.PlayCover/Applications/jp.co.bandainamcoent.BNEI0421.app"
if [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist")" != '3.4.0' ] ||
   [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist")" != '89' ]; then
  echo 'Backup belongs to Gakumas 3.4.0 build 89; refusing another version.' >&2; exit 1
fi
if /usr/bin/pgrep -x idolmaster_gakuen >/dev/null; then
  echo 'Quit the game before rolling back the PoC.' >&2; exit 1
fi
test -f "$POC/private-backup/idolmaster_gakuen.before-compat"
test -s "$POC/private-backup/entitlements.plist"
cp -p "$POC/private-backup/idolmaster_gakuen.before-compat" "$APP/idolmaster_gakuen"
chmod 755 "$APP/idolmaster_gakuen"
if [ -f "$APP/Frameworks/GakuPlayChainCompat.dylib" ]; then
  mkdir -p "$POC/build"
  mv "$APP/Frameworks/GakuPlayChainCompat.dylib" "$POC/build/GakuPlayChainCompat.removed.dylib"
fi
codesign --force --sign - --entitlements "$POC/private-backup/entitlements.plist" "$APP/idolmaster_gakuen"
codesign --force --sign - --entitlements "$POC/private-backup/entitlements.plist" "$APP"
codesign --verify --verbose "$APP"
echo 'Compatibility PoC removed; Korean patch and login database preserved.'
