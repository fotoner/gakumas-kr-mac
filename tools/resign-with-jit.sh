#!/bin/bash
# make run: 주입 dylib 점검 → 로그인 DB preflight → JIT 엔타이틀먼트 재서명 → 직접 실행
# PlayCover Play 버튼 금지 (재서명 + KeyCover 가 오래된 .keyCover 로 로그인 DB 롤백)
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

ensure_devtools
APP=$(find_app)
BIN=$(app_exec "$APP")
log "앱: $APP — $(app_version "$APP")"
refuse_if_running "$(basename "$BIN")"

for name in GakumasLocalifyIOS_KR libdobby; do
  n=$(count_loads "$BIN" "$name")
  [ "$n" = 1 ] || die "$name 로드 커맨드 ${n}개 (정상: 1) — make patch 필요"
  [ -f "$APP/Frameworks/$name.dylib" ] || die "Frameworks/$name.dylib 없음 — make patch 필요"
done
n=$(count_loads "$BIN" GakuPlayChainCompat)
if [ "$n" = 0 ]; then
  warn "로그인 유지 수정 미설치 — 재실행 때 로그인이 풀릴 수 있음 (bash tools/login-persistence-poc/apply.sh)"
elif [ ! -f "$APP/Frameworks/GakuPlayChainCompat.dylib" ]; then
  die "GakuPlayChainCompat 를 로드하는데 Frameworks 에 dylib 없음 — 앱이 시작되지 않음 (apply.sh 재실행)"
fi

log "PlayChain 로그인 DB 점검"
python3 "$GAKU_TOOLS/login-persistence-poc/playchain-recover.py" preflight ||
  die "PlayChain preflight 거부 — 게임을 실행하지 않음"

log "JIT 엔타이틀먼트 재서명"
init_tmp
ENT="$GAKU_TMP/entitlements.plist"
read_ent "$BIN" "$ENT"
jit_keys "$ENT" add
sign_main "$APP" "$BIN" "$ENT"
has_jit "$BIN" || die "재서명 후에도 allow-jit 없음"
echo "✓ JIT 엔타이틀먼트 재적용 완료"

echo ""
echo "앱 직접 실행 (PlayCover 우회):"
/usr/bin/open "$APP"
