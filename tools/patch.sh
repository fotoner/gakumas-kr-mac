#!/bin/bash
# gakumas-kr-mac 패치 적용 (10단계 통합)
# 전제: IPA로 학원마스가 설치된 Mac IPA 런타임 + ios/GakumasLocalifyIOS_KR.dylib 존재
# 검증된 런타임: PlayCover (아래 APP 경로). 다른 런타임이면 APP 변수를 해당 번들 경로로 수정.
set -e

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# IPA 런타임별 번들 경로 — PlayCover 기본값
APP="${APP:-$HOME/Library/Containers/io.playcover.PlayCover/Applications/jp.co.bandainamcoent.BNEI0421.app}"
BIN="$APP/idolmaster_gakuen"
KR_SRC="$ROOT/ios/GakumasLocalifyIOS_KR.dylib"
KR_DST="$APP/Frameworks/GakumasLocalifyIOS_KR.dylib"
DOBBY_SRC="$ROOT/tools/libdobby.dylib"
DOBBY_DST="$APP/Frameworks/libdobby.dylib"
INSERTER="$ROOT/tools/insert_dylib"
ENT="/tmp/gaku-entitlements.plist"

log() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# --- 전제 검사 ---
[ -d "$APP" ] || die "학원마스 앱 번들을 찾을 수 없음: $APP (다른 IPA 런타임이면 APP 환경변수로 지정)"
[ -f "$KR_SRC" ] || die "한국어 dylib이 없음: $KR_SRC"
[ -x "$INSERTER" ] || die "insert_dylib 바이너리가 없음: $INSERTER (make setup 실행 필요)"
[ -f "$DOBBY_SRC" ] || die "libdobby.dylib이 없음: $DOBBY_SRC (make setup 실행 필요)"

# 게임 실행 중이면 중단
if pgrep -f "idolmaster_gakuen" > /dev/null; then
  die "학원마스가 실행 중임. 먼저 종료(⌘Q) 후 재시도."
fi

# --- Step 1: 원본 백업 ---
log "[1/8] 원본 바이너리 백업"
if [ ! -f "$BIN.orig" ]; then
  cp "$BIN" "$BIN.orig"
  PLAYTOOLS_HASH=$(shasum -a 256 ~/Library/Frameworks/PlayTools.framework/PlayTools 2>/dev/null | cut -d' ' -f1)
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
TMP_KR="/tmp/gaku-kr-mc.dylib"
vtool -set-build-version maccatalyst 11.0 14.0 -replace -output "$TMP_KR" "$KR_SRC" 2>&1 | tail -1

# --- Step 3: dylib 복사 ---
log "[3/8] dylib 복사 → Frameworks/"
cp "$TMP_KR" "$KR_DST"
cp "$DOBBY_SRC" "$DOBBY_DST"
rm -f "$TMP_KR"

# --- Step 4: LC_LOAD_DYLIB 주입 (idempotent) ---
log "[4/8] 메인 바이너리에 LC_LOAD_DYLIB 추가"
if ! otool -L "$BIN" | grep -q GakumasLocalifyIOS_KR; then
  "$INSERTER" --inplace --all-yes "@rpath/GakumasLocalifyIOS_KR.dylib" "$BIN" | tail -1
  echo "    KR dylib 엔트리 추가됨"
fi
if ! otool -L "$BIN" | grep -q libdobby; then
  "$INSERTER" --inplace --all-yes "@rpath/libdobby.dylib" "$BIN" | tail -1
  echo "    Dobby 엔트리 추가됨"
fi

# --- Step 5: JIT 엔타이틀먼트 준비 ---
log "[5/8] JIT 엔타이틀먼트 주입"
codesign -d --entitlements - --xml "$BIN" 2>/dev/null > "$ENT"
for key in \
  com.apple.security.cs.allow-jit \
  com.apple.security.cs.disable-executable-page-protection \
  com.apple.security.cs.allow-unsigned-executable-memory \
  com.apple.security.cs.disable-library-validation \
  com.apple.security.get-task-allow; do
  /usr/libexec/PlistBuddy -c "Add ':$key' bool true" "$ENT" 2>/dev/null || true
done

# --- Step 6: 재서명 (inner → outer) ---
log "[6/8] 재서명 (inner → outer)"
codesign --force --sign - "$DOBBY_DST" 2>&1 | tail -1
codesign --force --sign - "$KR_DST" 2>&1 | tail -1
for fw in "$APP/Frameworks"/*.framework; do
  fwname=$(basename "$fw" .framework)
  [ -f "$fw/$fwname" ] && codesign --force --sign - --preserve-metadata=entitlements,flags "$fw/$fwname" 2>/dev/null
  codesign --force --sign - --preserve-metadata=entitlements,flags "$fw" 2>/dev/null
done
for pi in "$APP/PlugIns"/*; do
  [ -e "$pi" ] && codesign --force --sign - --preserve-metadata=entitlements,flags "$pi" 2>/dev/null
done
codesign --force --sign - --entitlements "$ENT" "$BIN" 2>&1 | tail -1
codesign --force --sign - --entitlements "$ENT" "$APP" 2>&1 | tail -1

# --- Step 7: 검증 ---
log "[7/8] 검증"
codesign --verify --verbose "$APP" 2>&1 | head -2
otool -L "$BIN" | grep -E "Gakumas|libdobby" | sed 's/^/    /'
codesign -d --entitlements - "$BIN" 2>&1 | grep "allow-jit" > /dev/null && \
  echo "    JIT 엔타이틀먼트 OK" || echo "    ⚠ JIT 엔타이틀먼트 확인 필요"

# --- Step 8: 설정 파일 배치 (첫 실행 후에만 가능) ---
log "[8/8] 설정 파일 배치"
GAKU_DIR=$(find "$HOME/Library/Containers" -maxdepth 5 -type d -name "gakumas-localify" 2>/dev/null | head -1)
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
  [ -f "$ROOT/tools/localizationConfig.json" ] && \
    cp "$ROOT/tools/localizationConfig.json" "$GAKU_DIR/localizationConfig.json"
  echo "    설정 파일 배치됨: $GAKU_DIR"
else
  echo "    (gakumas-localify 폴더가 아직 없음. 게임 첫 실행 후 재실행하면 설정 파일도 배치됨)"
fi

echo ""
echo "================================================================"
echo "패치 적용 완료."
echo ""
echo "실행:   bash $ROOT/tools/resign-with-jit.sh"
echo "로그:   bash $ROOT/tools/watch-logs.sh"
echo "복원:   bash $ROOT/tools/revert.sh"
echo "================================================================"
