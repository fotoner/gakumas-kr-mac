#!/bin/bash
# make run: 로그인 DB preflight → 주입 dylib 검증 → JIT 엔타이틀먼트 재서명 → 직접 실행 (PlayCover 우회)
# PlayCover Play 버튼은 쓰지 말 것 (재서명 + KeyCover 가 오래된 .keyCover 로 로그인 DB 롤백 / 종료 시 .db 잠금·삭제)
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

APP=$(find_app)
BIN=$(app_exec "$APP")
ENT=""
cleanup() { if [ -n "$ENT" ]; then rm -f "$ENT"; fi; }
trap cleanup EXIT

log "앱: $APP — $(app_version "$APP")"
refuse_if_running "$(basename "$BIN")"

# --- 주입 dylib 검증 (각 1회 로드 + Frameworks 에 실파일) ---
for name in GakumasLocalifyIOS_KR libdobby; do
  n=$(count_loads "$BIN" "$name")
  [ "$n" = 1 ] || die "$name 로드 커맨드 ${n}개 (정상: 1) — make patch 필요"
  [ -f "$APP/Frameworks/$name.dylib" ] || die "$APP/Frameworks/$name.dylib 없음 — make patch 필요"
done
n=$(count_loads "$BIN" GakuPlayChainCompat)
case "$n" in
  0) warn "로그인 유지 수정(GakuPlayChainCompat) 미설치 — 재실행 때 로그인이 풀릴 수 있음 (설치: bash tools/login-persistence-poc/apply.sh)" ;;
  1) [ -f "$APP/Frameworks/GakuPlayChainCompat.dylib" ] ||
       die "바이너리는 GakuPlayChainCompat 를 로드하는데 Frameworks/GakuPlayChainCompat.dylib 가 없음 — 이대로면 앱이 시작되지 않음 (apply.sh 재실행 또는 rollback.sh)" ;;
  *) die "GakuPlayChainCompat 로드 커맨드 ${n}개 — rollback.sh 후 apply.sh 재실행" ;;
esac

# --- 로그인 DB preflight (거부 시 실행 안 함) ---
log "PlayChain 로그인 DB 점검"
gaku_py "$GAKU_TOOLS/login-persistence-poc/playchain-recover.py" preflight ||
  die "PlayChain preflight 거부 — 게임을 실행하지 않음 (위 메시지 참고)"

# --- JIT 엔타이틀먼트 재서명 (매번 현재 바이너리에서 새로 생성) ---
log "JIT 엔타이틀먼트 재서명"
ENT=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/gaku-entitlements.XXXXXX")
if ! dump_entitlements "$BIN" "$ENT"; then
  warn "현재 바이너리에서 엔타이틀먼트를 읽지 못함 — .orig 의 것을 사용"
  dump_entitlements "$BIN.orig" "$ENT" || die "엔타이틀먼트를 읽지 못함 ($BIN, $BIN.orig) — make patch 재실행 필요"
fi
ensure_app_entitlements "$BIN" "$ENT"
set_jit_keys "$ENT"
sign_main "$APP" "$BIN" "$ENT"
has_jit "$BIN" || die "재서명 후에도 allow-jit 가 없음"
echo "✓ JIT 엔타이틀먼트 재적용 완료"

if [ "${GAKU_TEST_NO_OPEN:-}" = 1 ]; then
  echo "[테스트] GAKU_TEST_NO_OPEN=1 — open 생략"
  exit 0
fi
echo ""
echo "앱 직접 실행 (PlayCover 우회):"
/usr/bin/open "$APP"
