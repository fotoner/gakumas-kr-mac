#!/bin/bash
# gakumas-kr-mac 패치 적용 (8단계 통합)
# 전제: IPA로 학원마스가 설치된 Mac IPA 런타임 + ios/GakumasLocalifyIOS_KR.dylib 존재
# 앱 위치는 자동 탐색 (/Applications, ~/Applications, PlayCover Applications). 그 밖이면 APP=<.app 경로>.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

ROOT="$GAKU_ROOT"
KR_SRC="$ROOT/ios/GakumasLocalifyIOS_KR.dylib"
DOBBY_SRC="$ROOT/tools/libdobby.dylib"
INSERTER="$ROOT/tools/insert_dylib"

TMP_KR=""; ENT=""
cleanup() { for f in "$TMP_KR" "$ENT"; do if [ -n "$f" ]; then rm -f "$f"; fi; done; }
trap cleanup EXIT

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

# 게임 실행 중이면 중단
refuse_if_running "$(basename "$BIN")"

# --- Step 1: 원본 백업 ---
log "[1/8] 원본 바이너리 백업"
if [ ! -f "$BIN.orig" ]; then
  for name in GakumasLocalifyIOS_KR libdobby GakuPlayChainCompat; do
    n=$(count_loads "$BIN" "$name")
    [ "$n" = 0 ] ||
      die "$BIN 이 이미 패치된 상태($name)인데 .orig 백업이 없음 — 원본이 아니므로 백업하지 않음 (IPA 재임포트 필요)"
  done
  cp -p "$BIN" "$BIN.orig"
  PLAYTOOLS_HASH=$(/usr/bin/shasum -a 256 "$HOME/Library/Frameworks/PlayTools.framework/PlayTools" 2>/dev/null | cut -d' ' -f1 || true)
  cat > "$BIN.orig.meta.json" <<EOF
{
  "playtools_sha256": "$PLAYTOOLS_HASH",
  "backup_timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
  echo "    백업 생성됨"
else
  # insert_dylib/codesign 은 LC_UUID 를 바꾸지 않음 → 같은 빌드의 .orig 면 UUID 일치
  U_ORIG=$(macho_uuid "$BIN.orig"); U_BIN=$(macho_uuid "$BIN")
  [ "$U_ORIG" = "$U_BIN" ] ||
    die "기존 $BIN.orig 가 현재 바이너리와 다른 빌드 (LC_UUID ${U_ORIG:0:8} ≠ ${U_BIN:0:8}) — 게임 업데이트 전 백업으로 보임.
  삭제하지 말고 앱 번들 밖으로 옮겨 보관한 뒤 make patch 재실행 (현재 바이너리가 원본이면 새 .orig 를 만듦)"
  echo "    기존 백업 유지 (같은 빌드)"
fi

# 엔타이틀먼트는 바이너리를 건드리기 전에 확보 (insert_dylib 이 서명을 지움)
ENT=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/gaku-entitlements.XXXXXX")
if ! dump_entitlements "$BIN" "$ENT" && ! dump_entitlements "$BIN.orig" "$ENT"; then
  warn "기존 엔타이틀먼트 없음 ($BIN, $BIN.orig)"
  write_empty_plist "$ENT"
fi
ensure_app_entitlements "$BIN" "$ENT"   # PlayCover 앱인데 app-sandbox 없으면 여기서 중단

# --- Step 2: KR dylib 플랫폼 변환 ---
log "[2/8] KR dylib 플랫폼 변환 (iOS → macCatalyst)"
TMP_KR=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/gaku-kr-mc.XXXXXX")
/usr/bin/vtool -set-build-version maccatalyst 11.0 14.0 -replace -output "$TMP_KR" "$KR_SRC" >/dev/null
[ -s "$TMP_KR" ] || die "vtool 출력이 비어 있음: $TMP_KR"
BUILD_INFO=$(/usr/bin/vtool -show-build "$TMP_KR")
case "$BUILD_INFO" in *MACCATALYST*) ;; *) die "vtool 변환 결과가 macCatalyst 가 아님" ;; esac

# --- Step 3: dylib 복사 ---
log "[3/8] dylib 복사 → Frameworks/"
mkdir -p "$APP/Frameworks"
cp "$TMP_KR" "$KR_DST"
chmod 644 "$KR_DST"
cp "$DOBBY_SRC" "$DOBBY_DST"

# --- Step 4: LC_LOAD_DYLIB 주입 (idempotent — 없을 때만 추가, 결과는 정확히 1개) ---
log "[4/8] 메인 바이너리에 LC_LOAD_DYLIB 추가"
for name in GakumasLocalifyIOS_KR libdobby; do
  n=$(count_loads "$BIN" "$name")
  case "$n" in
    0) "$INSERTER" --inplace --all-yes "@rpath/$name.dylib" "$BIN" | tail -1
       echo "    $name 엔트리 추가됨" ;;
    1) echo "    $name 엔트리 이미 있음" ;;
    *) die "$name 로드 커맨드가 ${n}개 — .orig 복원(make revert) 후 재패치" ;;
  esac
  n=$(count_loads "$BIN" "$name")
  [ "$n" = 1 ] || die "$name 주입 후 로드 커맨드 ${n}개 (정상: 1)"
done

# --- Step 5: JIT 엔타이틀먼트 준비 ---
log "[5/8] JIT 엔타이틀먼트 주입"
set_jit_keys "$ENT"

# --- Step 6: 재서명 (inner → outer) ---
log "[6/8] 재서명 (inner → outer)"
/usr/bin/codesign --force --sign - "$DOBBY_DST"
/usr/bin/codesign --force --sign - "$KR_DST"
resign_nested "$APP"
sign_main "$APP" "$BIN" "$ENT"

# --- Step 7: 검증 ---
log "[7/8] 검증"
/usr/bin/codesign --verify --verbose "$APP" 2>&1 | sed -n '1,2p'
for name in GakumasLocalifyIOS_KR libdobby GakuPlayChainCompat; do
  n=$(count_loads "$BIN" "$name")
  echo "    $name: 로드 ${n}회"
done
if has_jit "$BIN"; then echo "    JIT 엔타이틀먼트 OK"; else die "JIT 엔타이틀먼트 없음"; fi

# --- Step 8: 설정 파일 배치 (첫 실행 후에만 가능) ---
log "[8/8] 설정 파일 배치"
if [ -n "${GAKU_LOCALIFY_DIR+x}" ]; then   # 테스트/비표준 런타임용 위치 지정
  GAKU_DIR="$GAKU_LOCALIFY_DIR"
  [ -d "$GAKU_DIR" ] || GAKU_DIR=""
else
  GAKU_DIR=$(find "$HOME/Library/Containers" -maxdepth 5 -type d -name "gakumas-localify" 2>/dev/null | head -1 || true)
fi
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
  if [ -f "$ROOT/tools/localizationConfig.json" ]; then
    cp "$ROOT/tools/localizationConfig.json" "$GAKU_DIR/localizationConfig.json"
  fi
  echo "    설정 파일 배치됨: $GAKU_DIR"
else
  echo "    (gakumas-localify 폴더가 아직 없음. 게임 첫 실행 후 재실행하면 설정 파일도 배치됨)"
fi

echo ""
echo "================================================================"
echo "패치 적용 완료."
echo ""
echo "실행:   make run   (또는 bash $ROOT/tools/resign-with-jit.sh)"
echo "로그:   bash $ROOT/tools/watch-logs.sh"
echo "복원:   bash $ROOT/tools/revert.sh"
echo "================================================================"
