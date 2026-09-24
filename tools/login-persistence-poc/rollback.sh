#!/bin/bash
# 로그인 유지 수정(GakuPlayChainCompat) 제거 — before-compat 백업으로 바이너리 복원 (한국어 패치/로그인 DB 는 유지)
# 백업 위치: GAKU_POC_BACKUP_DIR > tools/login-persistence-poc/private-backup > docs/login-persistence-poc/private-backup
set -euo pipefail
POC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$POC/../lib/common.sh"

EXPECT_VERSION="3.4.0 (89)"
APP=$(find_app)
BIN=$(app_exec "$APP")
DST="$APP/Frameworks/GakuPlayChainCompat.dylib"
PRIV=$(poc_backup_dir)
BC="$PRIV/idolmaster_gakuen.before-compat"
ENT=""
cleanup() { if [ -n "$ENT" ]; then rm -f "$ENT"; fi; }
trap cleanup EXIT

VER=$(app_version "$APP")
[ "$VER" = "$EXPECT_VERSION" ] || die "백업은 학원마스 $EXPECT_VERSION 용 — 찾은 앱: $VER ($APP). 다른 버전에는 복원하지 않음"
refuse_if_running "$(basename "$BIN")"
[ -f "$BC" ] || die "before-compat 백업 없음: $BC
  (2026-09-20 설치 때 백업은 $GAKU_ROOT/docs/login-persistence-poc/private-backup — 다른 곳이면 GAKU_POC_BACKUP_DIR=<폴더>)"
[ -s "$PRIV/entitlements.plist" ] || die "$PRIV/entitlements.plist 없음"
n=$(count_loads "$BC" GakuPlayChainCompat)
[ "$n" = 0 ] || die "백업 자체가 GakuPlayChainCompat 를 로드함 ($BC) — 복원해도 수정이 남으므로 중단"
U_BC=$(macho_uuid "$BC"); U_BIN=$(macho_uuid "$BIN")
[ "$U_BC" = "$U_BIN" ] ||
  die "백업과 현재 바이너리의 빌드가 다름 (LC_UUID 불일치) — 게임이 업데이트됐다면 make patch 후 필요 시 apply.sh 재설치"
for name in GakumasLocalifyIOS_KR libdobby; do
  n=$(count_loads "$BC" "$name")
  [ "$n" = 1 ] || warn "백업에 $name 로드가 ${n}개 — 복원 후 make patch 필요할 수 있음"
done
echo "앱: $APP — $VER"
echo "private-backup: $PRIV"

ENT=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/gaku-entitlements.XXXXXX")
if ! dump_entitlements "$BIN" "$ENT"; then
  warn "현재 서명에 엔타이틀먼트 없음 — $PRIV/entitlements.plist 사용"
  cp "$PRIV/entitlements.plist" "$ENT"
fi
ensure_app_entitlements "$BIN" "$ENT"

cp -p "$BC" "$BIN"
chmod 755 "$BIN"
if [ -f "$DST" ]; then
  KEEP="$PRIV/GakuPlayChainCompat.removed.$(sha8 "$DST").dylib"
  if [ -e "$KEEP" ]; then rm -f "$DST"; else mv "$DST" "$KEEP"; chmod 600 "$KEEP"; fi
  echo "제거한 dylib 보관: $KEEP"
fi
sign_main "$APP" "$BIN" "$ENT"
n=$(count_loads "$BIN" GakuPlayChainCompat)
[ "$n" = 0 ] || die "복원 후에도 GakuPlayChainCompat 로드 ${n}개"
echo "로그인 유지 수정 제거 완료 — 한국어 패치와 로그인 DB 는 그대로. 실행은 make run."
