#!/bin/bash
set -e
APP="$HOME/Library/Containers/io.playcover.PlayCover/Applications/jp.co.bandainamcoent.BNEI0421.app"
BIN="$APP/idolmaster_gakuen"

if [ ! -f "$BIN.orig" ]; then
  echo "ERROR: $BIN.orig 백업 없음, 복원 불가"
  exit 1
fi

echo "→ 원본 바이너리 복원"
cp "$BIN.orig" "$BIN"

echo "→ 주입된 dylib들 제거"
rm -f "$APP/Frameworks/GakumasLocalifyIOS_KR.dylib"
rm -f "$APP/Frameworks/libdobby.dylib"

echo "→ 재서명 (inner → outer)"
for fw in "$APP/Frameworks"/*.framework; do
  fwname=$(basename "$fw" .framework)
  [ -f "$fw/$fwname" ] && codesign --force --sign - "$fw/$fwname" 2>/dev/null
  codesign --force --sign - "$fw" 2>/dev/null
done
for pi in "$APP/PlugIns"/*; do
  [ -e "$pi" ] && codesign --force --sign - "$pi" 2>/dev/null
done
codesign --force --sign - "$BIN" 2>/dev/null
codesign --force --sign - "$APP" 2>/dev/null

echo "✓ 복원 완료"
