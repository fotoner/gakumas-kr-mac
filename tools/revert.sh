#!/bin/bash
# 패치 되돌리기: .orig 복원 + 주입 dylib 제거 + 재서명
# 엔타이틀먼트는 현재 것에서 JIT 키 5개만 뺌 (app-sandbox 등 앱 고유 키는 유지)
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

APP=$(find_app)
BIN=$(app_exec "$APP")
echo "앱: $APP — $(app_version "$APP")"
refuse_if_running "$(basename "$BIN")"
[ -f "$BIN.orig" ] || die "$BIN.orig 백업 없음, 복원 불가"

init_tmp
ENT="$GAKU_TMP/entitlements.plist"
read_ent "$BIN" "$ENT"
jit_keys "$ENT" del

echo "→ 원본 바이너리 복원 (.orig 는 보존)"
cp "$BIN.orig" "$BIN"
chmod 755 "$BIN"

echo "→ 주입된 dylib들 제거"
rm -f "$APP/Frameworks/GakumasLocalifyIOS_KR.dylib" "$APP/Frameworks/libdobby.dylib" \
      "$APP/Frameworks/GakuPlayChainCompat.dylib"

echo "→ 재서명 (JIT 키 제외)"
sign_main "$APP" "$BIN" "$ENT"
echo "✓ 복원 완료"
