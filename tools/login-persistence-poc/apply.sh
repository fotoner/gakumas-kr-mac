#!/bin/bash
# 로그인 유지 수정(GakuPlayChainCompat) 설치/업그레이드 — 학원마스 3.4.0 (89) 전용
#   신규: 바이너리를 건드리기 전에 before-compat 백업 + 엔타이틀먼트를 private-backup 에 저장
#         (기존 before-compat 는 절대 덮어쓰지 않음)
#   업그레이드(이미 로드 중): Frameworks 의 dylib 만 교체, 이전 것은 private-backup/GakuPlayChainCompat.<sha8>.dylib
# 환경변수: GAKU_POC_DYLIB (설치할 dylib, 기본 build/GakuPlayChainCompat.dylib), GAKU_POC_BACKUP_DIR
set -euo pipefail
POC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$POC/../lib/common.sh"

EXPECT_VERSION="3.4.0 (89)"
APP=$(find_app)
BIN=$(app_exec "$APP")
SRC="${GAKU_POC_DYLIB:-$POC/build/GakuPlayChainCompat.dylib}"
DST="$APP/Frameworks/GakuPlayChainCompat.dylib"
PRIV=$(poc_backup_dir)
BC="$PRIV/idolmaster_gakuen.before-compat"
ENT=""
cleanup() { if [ -n "$ENT" ]; then rm -f "$ENT"; fi; }
trap cleanup EXIT

VER=$(app_version "$APP")
[ "$VER" = "$EXPECT_VERSION" ] || die "이 PoC 는 학원마스 $EXPECT_VERSION 전용 — 찾은 앱: $VER ($APP)"
refuse_if_running "$(basename "$BIN")"
[ -f "$SRC" ] || die "설치할 dylib 없음: $SRC (python3 $POC/build-and-test.py 먼저)"
macho_uuid "$SRC" >/dev/null
[ -f "$BIN.orig" ] || die "$BIN.orig 없음 — make patch 먼저"
[ -x "$GAKU_TOOLS/insert_dylib" ] || die "insert_dylib 없음 — make setup 먼저"
echo "앱: $APP — $VER"
echo "private-backup: $PRIV"

# 서명용 엔타이틀먼트는 바이너리를 건드리기 전에 현재 서명에서 확보
ENT=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/gaku-entitlements.XXXXXX")
if ! dump_entitlements "$BIN" "$ENT"; then
  [ -s "$PRIV/entitlements.plist" ] || die "현재 바이너리 엔타이틀먼트를 읽지 못함 (서명 없음) — make run 또는 make patch 후 재시도"
  warn "현재 서명에 엔타이틀먼트 없음 — $PRIV/entitlements.plist 사용"
  cp "$PRIV/entitlements.plist" "$ENT"
fi
ensure_app_entitlements "$BIN" "$ENT"

n=$(count_loads "$BIN" GakuPlayChainCompat)
case "$n" in
0)
  if [ -f "$BC" ]; then
    m=$(count_loads "$BC" GakuPlayChainCompat)
    [ "$m" = 0 ] || die "기존 before-compat 백업이 GakuPlayChainCompat 를 로드함 ($BC) — 백업이 오염됨, 수동 확인 필요"
    U_BC=$(macho_uuid "$BC"); U_BIN=$(macho_uuid "$BIN")
    [ "$U_BC" = "$U_BIN" ] ||
      die "기존 before-compat 백업($BC)이 현재 빌드와 다름 (LC_UUID 불일치) — 덮어쓰지 않음. 옮기거나 GAKU_POC_BACKUP_DIR 로 새 위치 지정"
    [ -s "$PRIV/entitlements.plist" ] || die "$PRIV/entitlements.plist 없음 — before-compat 와 짝이 맞지 않음"
    echo "기존 before-compat 백업 유지 (덮어쓰지 않음): $BC"
  else
    (umask 077; mkdir -p "$PRIV")
    chmod 700 "$PRIV"
    if [ -e "$PRIV/entitlements.plist" ]; then
      mv "$PRIV/entitlements.plist" "$PRIV/entitlements.plist.$(date +%Y%m%d%H%M%S)"
    fi
    cp -p "$BIN" "$BC.tmp.$$"
    chmod 600 "$BC.tmp.$$"
    mv "$BC.tmp.$$" "$BC"
    cp "$ENT" "$PRIV/entitlements.plist"
    chmod 600 "$PRIV/entitlements.plist"
    echo "before-compat 백업 생성: $BC"
  fi
  cp "$SRC" "$DST"
  chmod 755 "$DST"
  /usr/bin/codesign --force --sign - "$DST"
  "$GAKU_TOOLS/insert_dylib" --inplace --all-yes '@rpath/GakuPlayChainCompat.dylib' "$BIN" | tail -1
  ;;
1)
  echo "업그레이드 모드: 이미 로드 중 — Frameworks 의 dylib 만 교체"
  [ -f "$BC" ] || warn "rollback 용 before-compat 백업이 $PRIV 에 없음 (이미 수정된 바이너리로는 만들지 않음)"
  if [ -f "$DST" ]; then
    (umask 077; mkdir -p "$PRIV")
    chmod 700 "$PRIV"
    KEEP="$PRIV/GakuPlayChainCompat.$(sha8 "$DST").dylib"
    if [ ! -e "$KEEP" ]; then
      cp -p "$DST" "$KEEP"
      chmod 600 "$KEEP"
    fi
    echo "이전 dylib 보관: $KEEP"
  else
    warn "Frameworks 에 dylib 가 없었음 (앱이 시작되지 않던 상태) — 새로 설치"
  fi
  cp "$SRC" "$DST"
  chmod 755 "$DST"
  /usr/bin/codesign --force --sign - "$DST"
  ;;
*)
  die "GakuPlayChainCompat 로드 커맨드 ${n}개 — rollback.sh 로 되돌린 뒤 재설치"
  ;;
esac

sign_main "$APP" "$BIN" "$ENT"
n=$(count_loads "$BIN" GakuPlayChainCompat)
[ "$n" = 1 ] || die "적용 후 GakuPlayChainCompat 로드 커맨드 ${n}개 (정상: 1)"
echo "적용 완료 (dylib sha256#$(sha8 "$DST")). 실행은 make run (또는 bash tools/resign-with-jit.sh)."
