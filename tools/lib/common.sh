# shellcheck shell=bash
# tools/*.sh 공용 헬퍼 — source 해서 사용 (set -euo pipefail 은 호출 스크립트 쪽에서)
# APP=<.app 경로> 로 앱 위치 직접 지정 가능 (검증은 동일)

GAKU_BUNDLE_ID="jp.co.bandainamcoent.BNEI0421"
GAKU_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GAKU_TOOLS="$GAKU_ROOT/tools"
GAKU_APP_DIRS=(/Applications "$HOME/Applications" "$HOME/Library/Containers/io.playcover.PlayCover/Applications")
# make run 이 넣고 revert 가 빼는 키 (그 밖의 app-sandbox 등은 항상 유지)
GAKU_JIT_KEYS="com.apple.security.cs.allow-jit
com.apple.security.cs.disable-executable-page-protection
com.apple.security.cs.allow-unsigned-executable-memory
com.apple.security.cs.disable-library-validation
com.apple.security.get-task-allow"

log()  { echo "==> $*"; }
warn() { echo "경고: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

plist_get() { /usr/libexec/PlistBuddy -c "Print ':$2'" "$1" 2>/dev/null; }

# 실폴더 + Info.plist/실행 파일이 실파일 + 번들 ID 일치.
# PlayCover 별칭(~/Applications/PlayCover/*.app)은 심볼릭 링크 묶음이라 여기서 걸러짐.
app_ok() {
  local exe
  [ -d "$1" ] && [ ! -L "$1" ] && [ -f "$1/Info.plist" ] && [ ! -L "$1/Info.plist" ] || return 1
  [ "$(plist_get "$1/Info.plist" CFBundleIdentifier)" = "$GAKU_BUNDLE_ID" ] || return 1
  exe=$(plist_get "$1/Info.plist" CFBundleExecutable) || return 1
  [ -f "$1/$exe" ] && [ ! -L "$1/$exe" ] && [ ! -L "$1/Frameworks" ]
}

find_app() {  # 학원마스 .app 경로를 stdout 으로. 0개/여러 개면 die.
  local d found=()
  if [ -n "${APP:-}" ]; then
    app_ok "${APP%/}" || die "APP=$APP 는 학원마스 .app 번들이 아님 (심볼릭 링크/PlayCover 별칭 불가)"
    echo "${APP%/}"; return 0
  fi
  for d in "${GAKU_APP_DIRS[@]}"; do
    if app_ok "$d/$GAKU_BUNDLE_ID.app"; then found+=("$d/$GAKU_BUNDLE_ID.app"); fi
  done
  case ${#found[@]} in
    1) echo "${found[0]}" ;;
    0) die "학원마스 앱 번들을 찾지 못함 (확인: ${GAKU_APP_DIRS[*]}, 별칭 제외) — APP=<.app 경로> 로 지정" ;;
    *) die "학원마스 앱 번들이 여러 곳에 있음: ${found[*]} — APP=<.app 경로> 로 하나를 지정" ;;
  esac
}

app_exec()    { echo "$1/$(plist_get "$1/Info.plist" CFBundleExecutable)"; }
app_version() { echo "$(plist_get "$1/Info.plist" CFBundleShortVersionString) ($(plist_get "$1/Info.plist" CFBundleVersion))"; }

# Xcode 라이선스 미동의면 xcrun 계열(vtool, /usr/bin/python3 …)이 exit 69 → CLT 로 우회
ensure_devtools() {
  /usr/bin/xcrun clang --version >/dev/null 2>&1 && return 0
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
  /usr/bin/xcrun clang --version >/dev/null 2>&1 ||
    die "개발 도구 사용 불가 — 'sudo xcodebuild -license accept' 또는 'xcode-select --install'"
}

# count_loads BIN NAME → 로드 커맨드 개수. 파싱 실패는 '없음'이 아니라 중단.
count_loads() {
  local out
  out=$(python3 "$GAKU_TOOLS/macho-loads.py" "$1" --count "$2") ||
    die "Mach-O 파싱 실패: $1 — 주입 상태를 알 수 없어 중단"
  case "$out" in ''|*[!0-9]*) die "macho-loads.py 출력 이상: $out" ;; esac
  echo "$out"
}

refuse_if_running() {
  local n
  for n in "$@"; do
    if /usr/bin/pgrep -x "$n" >/dev/null; then die "$n 실행 중 — 먼저 종료(⌘Q) 후 재시도"; fi
  done
}

sha8() { /usr/bin/shasum -a 256 "$1" | cut -c1-8; }

# 임시 폴더 GAKU_TMP (종료 시 삭제). $(...) 가 아니라 직접 호출할 것.
init_tmp() {
  GAKU_TMP=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/gaku.XXXXXX")
  trap 'rm -rf "$GAKU_TMP"' EXIT
}

# --- 엔타이틀먼트 / 서명 ---

# read_ent BIN OUT — 현재 서명의 엔타이틀먼트, 없으면(중단된 패치·예전 revert) BIN.orig 의 것.
# 빈 엔타이틀먼트로 서명하면 app-sandbox 가 사라지므로 둘 다 못 읽으면 중단.
read_ent() {
  local f
  for f in "$1" "$1.orig"; do
    /usr/bin/codesign -d --entitlements - --xml "$f" >"$2" 2>/dev/null || true
    [ -s "$2" ] && /usr/bin/plutil -lint -s "$2" >/dev/null && break
  done
  [ -s "$2" ] && /usr/bin/plutil -lint -s "$2" >/dev/null ||
    die "엔타이틀먼트를 읽지 못함: $1 (.orig 포함) — 빈 엔타이틀먼트로 서명하지 않음"
  plist_get "$2" com.apple.security.app-sandbox >/dev/null || warn "엔타이틀먼트에 app-sandbox 없음: $1"
}

jit_keys() {  # jit_keys ENT add|del — 키에 점이 있어 PlistBuddy 경로는 작은따옴표로
  local k
  for k in $GAKU_JIT_KEYS; do
    /usr/libexec/PlistBuddy -c "Delete ':$k'" "$1" >/dev/null 2>&1 || true
    if [ "$2" = add ]; then /usr/libexec/PlistBuddy -c "Add ':$k' bool true" "$1" >/dev/null; fi
  done
}

has_jit() {  # has_jit BIN — init_tmp 필요
  /usr/bin/codesign -d --entitlements - --xml "$1" >"$GAKU_TMP/check.plist" 2>/dev/null &&
    [ "$(plist_get "$GAKU_TMP/check.plist" com.apple.security.cs.allow-jit)" = true ]
}

sign_main() {  # sign_main APP BIN ENT — 메인 바이너리 → 앱 번들 순
  /usr/bin/codesign --force --sign - --entitlements "$3" "$2"
  /usr/bin/codesign --force --sign - --entitlements "$3" "$1"
  /usr/bin/codesign --verify "$1" || die "서명 검증 실패: $1"
}

# login-persistence-poc 백업 폴더: before-compat 가 있는 곳 (2026-09-20 설치분은 docs/…), 없으면 tools/…
poc_backup_dir() {
  local d
  for d in "$GAKU_TOOLS/login-persistence-poc/private-backup" "$GAKU_ROOT/docs/login-persistence-poc/private-backup"; do
    if [ -f "$d/idolmaster_gakuen.before-compat" ]; then echo "$d"; return 0; fi
  done
  echo "$GAKU_TOOLS/login-persistence-poc/private-backup"
}
