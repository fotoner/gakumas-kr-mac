#!/bin/bash
# 게임 실행 직전에 JIT 엔타이틀먼트 재서명. PlayCover가 덮어쓰는 타이밍 회피용.
set -e
APP="$HOME/Library/Containers/io.playcover.PlayCover/Applications/jp.co.bandainamcoent.BNEI0421.app"
BIN="$APP/idolmaster_gakuen"
ENT="/tmp/gaku-entitlements.plist"

if [ ! -f "$ENT" ]; then
  echo "엔타이틀먼트 파일 생성..."
  codesign -d --entitlements - --xml "$BIN" > "$ENT"
  /usr/libexec/PlistBuddy -c "Add ':com.apple.security.cs.allow-jit' bool true" "$ENT" 2>/dev/null
  /usr/libexec/PlistBuddy -c "Add ':com.apple.security.cs.disable-executable-page-protection' bool true" "$ENT" 2>/dev/null
  /usr/libexec/PlistBuddy -c "Add ':com.apple.security.cs.allow-unsigned-executable-memory' bool true" "$ENT" 2>/dev/null
  /usr/libexec/PlistBuddy -c "Add ':com.apple.security.cs.disable-library-validation' bool true" "$ENT" 2>/dev/null
  /usr/libexec/PlistBuddy -c "Add ':com.apple.security.get-task-allow' bool true" "$ENT" 2>/dev/null
fi

codesign --force --sign - --entitlements "$ENT" "$BIN"
codesign --force --sign - --entitlements "$ENT" "$APP"
echo "✓ JIT 엔타이틀먼트 재적용 완료"
codesign -d --entitlements - "$BIN" 2>&1 | grep -E "allow-jit" | head -3

# 즉시 앱 직접 실행 (PlayCover 우회) — 이렇게 하면 PlayCover가 재서명할 기회 없음
echo ""
echo "앱 직접 실행 (PlayCover 우회):"
open "$APP"
