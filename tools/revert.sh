#!/bin/bash
# 패치 되돌리기: .orig 복원 + 주입 dylib 제거 + 재서명
# 앱 고유 엔타이틀먼트(app-sandbox 등)는 유지하고 make run 이 넣은 JIT/디버그 키 5개만 제거.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

APP=$(find_app)
BIN=$(app_exec "$APP")
ENT=""
cleanup() { if [ -n "$ENT" ]; then rm -f "$ENT"; fi; }
trap cleanup EXIT

echo "앱: $APP — $(app_version "$APP")"
refuse_if_running "$(basename "$BIN")"
[ -f "$BIN.orig" ] || die "$BIN.orig 백업 없음, 복원 불가"
for name in GakumasLocalifyIOS_KR libdobby GakuPlayChainCompat; do
  n=$(count_loads "$BIN.orig" "$name")
  [ "$n" = 0 ] || die "$BIN.orig 가 원본이 아님 ($name 로드 ${n}개) — 복원 중단"
done
# insert_dylib/codesign 은 LC_UUID 를 바꾸지 않음 → 같은 빌드의 .orig 면 UUID 일치
U_ORIG=$(macho_uuid "$BIN.orig"); U_BIN=$(macho_uuid "$BIN")
[ "$U_ORIG" = "$U_BIN" ] ||
  die "$BIN.orig 가 현재 바이너리와 다른 빌드 (LC_UUID ${U_ORIG:0:8} ≠ ${U_BIN:0:8}) — 게임 업데이트 전 백업으로 보임. 복원하면 새 번들에 옛 실행 파일이 들어가므로 중단 (IPA 재임포트 필요)"

# 복원 전에 현재 서명의 엔타이틀먼트 확보 (없으면 .orig 의 것)
ENT=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/gaku-entitlements.XXXXXX")
if ! dump_entitlements "$BIN" "$ENT" && ! dump_entitlements "$BIN.orig" "$ENT"; then
  die "엔타이틀먼트를 읽지 못함 — 이대로 재서명하면 app-sandbox 등이 사라지므로 중단"
fi
ensure_app_entitlements "$BIN" "$ENT"
del_jit_keys "$ENT"

echo "→ 원본 바이너리 복원 (.orig 는 보존)"
cp "$BIN.orig" "$BIN"
chmod 755 "$BIN"

echo "→ 주입된 dylib들 제거"
rm -f "$APP/Frameworks/GakumasLocalifyIOS_KR.dylib" \
      "$APP/Frameworks/libdobby.dylib" \
      "$APP/Frameworks/GakuPlayChainCompat.dylib"

echo "→ 재서명 (inner → outer, JIT/디버그 키 제외)"
resign_nested "$APP"
sign_main "$APP" "$BIN" "$ENT"
if has_jit "$BIN"; then die "재서명 후에도 allow-jit 가 남아 있음"; fi

echo "✓ 복원 완료"
