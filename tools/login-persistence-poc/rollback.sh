#!/bin/bash
# 로그인 유지 수정(GakuPlayChainCompat) 제거 — before-compat 백업으로 바이너리 복원 (한국어 패치/로그인 DB 는 유지)
set -euo pipefail
POC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$POC/../lib/common.sh"

ensure_devtools
APP=$(find_app)
BIN=$(app_exec "$APP")
DST="$APP/Frameworks/GakuPlayChainCompat.dylib"
PRIV=$(poc_backup_dir)
BC="$PRIV/idolmaster_gakuen.before-compat"

EXPECT_VERSION="3.4.0 (89)"   # apply.sh 와 같이 갱신
VER=$(app_version "$APP")
[ "$VER" = "$EXPECT_VERSION" ] || die "백업은 학원마스 $EXPECT_VERSION 용 — 찾은 버전: $VER. 다른 버전에는 복원하지 않음"
refuse_if_running "$(basename "$BIN")"
[ -f "$BC" ] || die "before-compat 백업 없음: $BC"
n=$(count_loads "$BC" GakuPlayChainCompat)
[ "$n" = 0 ] || die "백업 자체가 GakuPlayChainCompat 를 로드함 ($BC) — 복원해도 수정이 남으므로 중단"
echo "앱: $APP — $VER"
echo "private-backup: $PRIV"

init_tmp
ENT="$GAKU_TMP/entitlements.plist"
read_ent "$BIN" "$ENT"

cp "$BC" "$BIN"
chmod 755 "$BIN"
if [ -f "$DST" ]; then
  KEEP="$PRIV/GakuPlayChainCompat.$(sha8 "$DST").dylib"
  mv -f "$DST" "$KEEP"
  chmod 600 "$KEEP"
  echo "제거한 dylib 보관: $KEEP"
fi
sign_main "$APP" "$BIN" "$ENT"
echo "로그인 유지 수정 제거 완료 — 한국어 패치와 로그인 DB 는 그대로. 실행은 make run."
