#!/bin/bash
# 로그인 유지 수정(GakuPlayChainCompat) 설치 — EXPECT_VERSION 의 게임 버전 전용
#   신규: before-compat 백업(이미 있으면 유지) → dylib 설치 + LC_LOAD_DYLIB 주입
#   업그레이드(이미 로드 중): Frameworks 의 dylib 만 교체, 이전 것은 private-backup/GakuPlayChainCompat.<sha8>.dylib
set -euo pipefail
POC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$POC/../lib/common.sh"

ensure_devtools
APP=$(find_app)
BIN=$(app_exec "$APP")
SRC="$POC/build/GakuPlayChainCompat.dylib"
DST="$APP/Frameworks/GakuPlayChainCompat.dylib"
PRIV=$(poc_backup_dir)
BC="$PRIV/idolmaster_gakuen.before-compat"

EXPECT_VERSION="3.4.0 (89)"   # 게임 업데이트 시 build-and-test.py 재검증 후 갱신 (rollback.sh 도)
VER=$(app_version "$APP")
[ "$VER" = "$EXPECT_VERSION" ] || die "학원마스 $EXPECT_VERSION 전용 — 찾은 버전: $VER ($APP)"
refuse_if_running "$(basename "$BIN")"
[ -f "$SRC" ] || die "$SRC 없음 — python3 $POC/build-and-test.py 먼저"
[ -f "$BIN.orig" ] || die "$BIN.orig 없음 — make patch 먼저"
[ -x "$GAKU_TOOLS/insert_dylib" ] || die "insert_dylib 없음 — make setup 먼저"
echo "앱: $APP — $VER"
echo "private-backup: $PRIV"

init_tmp
ENT="$GAKU_TMP/entitlements.plist"
read_ent "$BIN" "$ENT"   # insert_dylib 이 서명을 지우므로 먼저 확보
mkdir -p -m 700 "$PRIV"

n=$(count_loads "$BIN" GakuPlayChainCompat)
case "$n" in
  0)
    if [ -f "$BC" ]; then
      echo "기존 before-compat 백업 유지: $BC"
    else
      cp -p "$BIN" "$BC"
      chmod 600 "$BC"
      echo "before-compat 백업 생성: $BC"
    fi
    install -m 755 "$SRC" "$DST"
    /usr/bin/codesign --force --sign - "$DST"
    "$GAKU_TOOLS/insert_dylib" --inplace --all-yes '@rpath/GakuPlayChainCompat.dylib' "$BIN" >/dev/null ;;
  1)
    echo "업그레이드: 이미 로드 중 — Frameworks 의 dylib 만 교체"
    if [ -f "$DST" ]; then
      KEEP="$PRIV/GakuPlayChainCompat.$(sha8 "$DST").dylib"
      [ -e "$KEEP" ] || install -m 600 "$DST" "$KEEP"
      echo "이전 dylib 보관: $KEEP"
    fi
    install -m 755 "$SRC" "$DST"
    /usr/bin/codesign --force --sign - "$DST" ;;
  *) die "GakuPlayChainCompat 로드 커맨드 ${n}개 — rollback.sh 후 재설치" ;;
esac

sign_main "$APP" "$BIN" "$ENT"
n=$(count_loads "$BIN" GakuPlayChainCompat)
[ "$n" = 1 ] || die "적용 후 GakuPlayChainCompat 로드 커맨드 ${n}개 (정상: 1)"
echo "적용 완료 (dylib sha256 $(sha8 "$DST")). 실행은 make run."
