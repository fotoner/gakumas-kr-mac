#!/bin/bash
# gakumas-kr-mac 패치 적용 (8단계 통합)
# 전제: IPA로 학원마스가 설치된 Mac IPA 런타임 + ios/GakumasLocalifyIOS_KR.dylib 존재
# 앱 위치는 자동 탐색 (/Applications, ~/Applications, PlayCover). 그 밖이면 APP=<.app 경로>.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

ROOT="$GAKU_ROOT"
KR_SRC="$ROOT/ios/GakumasLocalifyIOS_KR.dylib"
DOBBY_SRC="$ROOT/tools/libdobby.dylib"
INSERTER="$ROOT/tools/insert_dylib"

# --- 전제 검사 ---
ensure_devtools
APP=$(find_app)
BIN=$(app_exec "$APP")
KR_DST="$APP/Frameworks/GakumasLocalifyIOS_KR.dylib"
DOBBY_DST="$APP/Frameworks/libdobby.dylib"
[ -f "$KR_SRC" ] || die "한국어 dylib이 없음: $KR_SRC"
[ -x "$INSERTER" ] || die "insert_dylib 바이너리가 없음: $INSERTER (make setup 실행 필요)"
[ -f "$DOBBY_SRC" ] || die "libdobby.dylib이 없음: $DOBBY_SRC (make setup 실행 필요)"
echo "앱: $APP — $(app_version "$APP")"
refuse_if_running "$(basename "$BIN")"

init_tmp
ENT="$GAKU_TMP/entitlements.plist"
TMP_KR="$GAKU_TMP/GakumasLocalifyIOS_KR.dylib"
read_ent "$BIN" "$ENT"   # insert_dylib 이 서명을 지우므로 바이너리를 건드리기 전에 확보

# --- Step 1: 원본 백업 ---
log "[1/8] 원본 바이너리 백업"
if [ ! -f "$BIN.orig" ]; then
  cp "$BIN" "$BIN.orig"
  PLAYTOOLS_HASH=$(/usr/bin/shasum -a 256 "$HOME/Library/Frameworks/PlayTools.framework/PlayTools" 2>/dev/null | cut -d' ' -f1 || true)
  cat > "$BIN.orig.meta.json" <<EOF
{
  "playtools_sha256": "$PLAYTOOLS_HASH",
  "backup_timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
  echo "    백업 생성됨"
else
  echo "    기존 백업 유지"
fi

# --- Step 2: KR dylib 플랫폼 변환 ---
log "[2/8] KR dylib 플랫폼 변환 (iOS → macCatalyst)"
/usr/bin/vtool -set-build-version maccatalyst 11.0 14.0 -replace -output "$TMP_KR" "$KR_SRC"
[ -s "$TMP_KR" ] || die "vtool 변환 결과가 비어 있음"

# --- Step 3: dylib 복사 ---
log "[3/8] dylib 복사 → Frameworks/"
cp "$TMP_KR" "$KR_DST"
cp "$DOBBY_SRC" "$DOBBY_DST"

# --- Step 4: LC_LOAD_DYLIB 주입 (idempotent — 없을 때만 추가) ---
log "[4/8] 메인 바이너리에 LC_LOAD_DYLIB 추가"
for name in GakumasLocalifyIOS_KR libdobby; do
  n=$(count_loads "$BIN" "$name")
  case "$n" in
    0) "$INSERTER" --inplace --all-yes "@rpath/$name.dylib" "$BIN" >/dev/null
       echo "    $name 엔트리 추가됨" ;;
    1) echo "    $name 엔트리 이미 있음" ;;
    *) die "$name 로드 커맨드가 ${n}개 — make revert 후 재패치" ;;
  esac
done

# --- Step 5: JIT 엔타이틀먼트 준비 ---
log "[5/8] JIT 엔타이틀먼트 주입"
jit_keys "$ENT" add

# --- Step 6: 재서명 (inner → outer) ---
log "[6/8] 재서명 (inner → outer)"
/usr/bin/codesign --force --sign - "$DOBBY_DST" "$KR_DST"
nested_sign() { /usr/bin/codesign --force --sign - --preserve-metadata=entitlements,flags "$1" 2>/dev/null || warn "서명 실패: $1"; }
for fw in "$APP/Frameworks"/*.framework; do
  fwname=$(basename "$fw" .framework)
  if [ -f "$fw/$fwname" ]; then nested_sign "$fw/$fwname"; fi
  if [ -d "$fw" ]; then nested_sign "$fw"; fi
done
for pi in "$APP/PlugIns"/*; do
  if [ -e "$pi" ]; then nested_sign "$pi"; fi
done
sign_main "$APP" "$BIN" "$ENT"

# --- Step 7: 검증 ---
log "[7/8] 검증"
for name in GakumasLocalifyIOS_KR libdobby; do
  n=$(count_loads "$BIN" "$name")
  [ "$n" = 1 ] || die "$name 로드 커맨드 ${n}개 (정상: 1)"
  echo "    $name 로드 1회"
done
has_jit "$BIN" || die "JIT 엔타이틀먼트 없음"
echo "    서명 + JIT 엔타이틀먼트 OK"

# --- Step 8: 설정 파일 배치 (첫 실행 후에만 가능) ---
log "[8/8] 설정 파일 배치"
GAKU_DIR=$(find "$HOME/Library/Containers" -maxdepth 5 -type d -name "gakumas-localify" 2>/dev/null | head -1 || true)
if [ -n "$GAKU_DIR" ]; then
  cat > "$GAKU_DIR/config.json" <<'EOF'
{
    "enableConsole": true,
    "transRemoteZipUrl": "",
    "useAPIAssets": true,
    "useAPIAssetsURL": "https://api.github.com/repos/pinisok/GakumasTranslationDataKorTest/releases/latest",
    "useRemoteAssets": true
}
EOF
  cp "$ROOT/tools/localizationConfig.json" "$GAKU_DIR/localizationConfig.json"
  echo "    설정 파일 배치됨: $GAKU_DIR"
else
  echo "    (gakumas-localify 폴더가 아직 없음. 게임 첫 실행 후 재실행하면 설정 파일도 배치됨)"
fi

echo ""
echo "================================================================"
echo "패치 적용 완료."
echo ""
echo "실행:   make run   (PlayCover Play 버튼 금지)"
echo "로그:   make logs"
echo "복원:   make revert"
echo "================================================================"
