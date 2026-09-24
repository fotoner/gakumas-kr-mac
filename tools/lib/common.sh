# shellcheck shell=bash
# tools/*.sh 공용 헬퍼 — source 해서 사용 (set -euo pipefail 은 호출 스크립트 쪽에서).
#
# 환경변수
#   APP                    학원마스 .app 경로 직접 지정 (지정해도 검증은 동일하게 수행)
#   GAKU_APP_SEARCH_DIRS   .app 을 찾을 폴더 목록 (':' 구분)
#                          기본: /Applications, ~/Applications, PlayCover Applications
#   GAKU_POC_BACKUP_DIR    login-persistence-poc private-backup 위치 강제 지정
#   GAKU_TEST_GUARD_PROCS  [테스트 전용] "실행 중이면 거부" 검사 대상 프로세스 이름 (공백 구분)

GAKU_BUNDLE_ID="jp.co.bandainamcoent.BNEI0421"
GAKU_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GAKU_TOOLS="$GAKU_ROOT/tools"
GAKU_PLAYCOVER_APPS="$HOME/Library/Containers/io.playcover.PlayCover/Applications"
# make run 이 추가하고 revert 가 제거하는 JIT/디버그 키
GAKU_JIT_KEYS="com.apple.security.cs.allow-jit
com.apple.security.cs.disable-executable-page-protection
com.apple.security.cs.allow-unsigned-executable-memory
com.apple.security.cs.disable-library-validation
com.apple.security.get-task-allow"

# 재서명 때 절대 잃으면 안 되는 앱 고유 키 (PlayCover: 샌드박스 + sbpl 예외)
GAKU_APP_KEYS="com.apple.security.app-sandbox
com.apple.security.temporary-exception.sbpl"

log()  { echo "==> $*"; }
warn() { echo "경고: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

plist_get() { /usr/libexec/PlistBuddy -c "Print ':$2'" "$1" 2>/dev/null; }

# --- 앱 번들 탐색 ----------------------------------------------------------

# 유효하면 아무것도 출력하지 않음. 아니면 이유 한 줄 출력.
# 실폴더 + Info.plist/메인 실행 파일이 실파일(심볼릭 링크 아님) + 번들 ID 일치만 허용.
# (~/Applications/PlayCover/*.app 같은 PlayCover 별칭 = 심볼릭 링크 묶음은 여기서 걸러짐)
app_problem() {
  local app="${1%/}" exe
  if [ -L "$app" ]; then echo "심볼릭 링크 (별칭은 사용 불가)"; return 0; fi
  if [ ! -e "$app" ]; then echo "없음"; return 0; fi
  if [ ! -d "$app" ]; then echo "폴더가 아님"; return 0; fi
  if [ -L "$app/Info.plist" ] || [ ! -f "$app/Info.plist" ]; then
    echo "Info.plist 가 실파일이 아님 (심볼릭 링크 묶음 별칭?)"; return 0
  fi
  if [ "$(plist_get "$app/Info.plist" CFBundleIdentifier || true)" != "$GAKU_BUNDLE_ID" ]; then
    echo "번들 ID 가 $GAKU_BUNDLE_ID 아님"; return 0
  fi
  exe=$(plist_get "$app/Info.plist" CFBundleExecutable || true)
  if [ -z "$exe" ] || [ -L "$app/$exe" ] || [ ! -f "$app/$exe" ]; then
    echo "메인 실행 파일(${exe:-?})이 실파일이 아님"; return 0
  fi
  if [ -L "$app/Frameworks" ]; then echo "Frameworks 가 심볼릭 링크"; return 0; fi
}

# 학원마스 .app 경로를 stdout 으로. 0개/여러 개면 die.
find_app() {
  local why d cand real found="" reals="" report="" n=0
  if [ -n "${APP:-}" ]; then
    why=$(app_problem "$APP")
    [ -z "$why" ] || die "APP=$APP 사용 불가: $why"
    echo "${APP%/}"
    return 0
  fi
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    cand="${d%/}/$GAKU_BUNDLE_ID.app"
    why=$(app_problem "$cand")
    report="$report
  - $cand: ${why:-OK}"
    [ -z "$why" ] || continue
    real=$(cd "$cand" && pwd -P)
    case "
$reals
" in *"
$real
"*) continue ;; esac   # 같은 실폴더를 가리키는 중복 후보
    reals="$reals
$real"
    found="$cand"
    n=$((n + 1))
  done <<EOF
$(printf '%s\n' "${GAKU_APP_SEARCH_DIRS:-/Applications:$HOME/Applications:$GAKU_PLAYCOVER_APPS}" | tr ':' '\n')
EOF
  if [ "$n" -eq 1 ]; then echo "$found"; return 0; fi
  if [ "$n" -eq 0 ]; then
    die "학원마스 앱 번들을 찾지 못함. 확인한 경로:$report
  (PlayCover 별칭 ~/Applications/PlayCover/*.app 은 심볼릭 링크 묶음이라 쓰지 않음)
  다른 위치면 APP=<.app 경로> 로 지정"
  fi
  die "학원마스 앱 번들이 여러 곳에 있음:$report
  APP=<.app 경로> 로 하나를 지정"
}

app_exec()    { echo "$1/$(plist_get "$1/Info.plist" CFBundleExecutable)"; }
app_version() { echo "$(plist_get "$1/Info.plist" CFBundleShortVersionString || echo '?') ($(plist_get "$1/Info.plist" CFBundleVersion || echo '?'))"; }

# --- 도구 ------------------------------------------------------------------

# Xcode 라이선스 미동의면 /usr/bin/xcrun 계열(vtool, clang, otool…)이 exit 69 → CLT 로 우회
ensure_devtools() {
  /usr/bin/xcrun clang --version >/dev/null 2>&1 && return 0
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
  /usr/bin/xcrun clang --version >/dev/null 2>&1 ||
    die "개발 도구 사용 불가 — 'sudo xcodebuild -license accept' 또는 'xcode-select --install'"
}

gaku_py() {
  if [ -z "${GAKU_PYTHON:-}" ]; then
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import sqlite3' >/dev/null 2>&1; then
      GAKU_PYTHON=python3
    else
      ensure_devtools
      GAKU_PYTHON=/usr/bin/python3
    fi
  fi
  "$GAKU_PYTHON" "$@"
}

# count_loads BIN NAME → NAME 로드 커맨드 개수. 파싱 실패(exit 2)는 '없음'이 아니라 치명적 오류.
count_loads() {
  local out
  if ! out=$(gaku_py "$GAKU_TOOLS/macho-loads.py" "$1" --count "$2"); then
    die "Mach-O 로드 커맨드 파싱 실패: $1 — 주입 상태를 알 수 없어 중단"
  fi
  case "$out" in ''|*[!0-9]*) die "macho-loads.py 출력 이상: $out" ;; esac
  echo "$out"
}

macho_uuid() {
  gaku_py "$GAKU_TOOLS/macho-loads.py" "$1" --uuid || die "LC_UUID 읽기 실패: $1"
}

sha8() { /usr/bin/shasum -a 256 "$1" | cut -c1-8; }

# --- 실행 중 검사 ----------------------------------------------------------

refuse_if_running() {  # refuse_if_running NAME...
  local names="$*" n
  if [ -n "${GAKU_TEST_GUARD_PROCS:-}" ]; then
    names="$GAKU_TEST_GUARD_PROCS"
    warn "[테스트] 실행 중 검사 대상을 '$names' 로 대체"
  fi
  for n in $names; do
    if /usr/bin/pgrep -x "$n" >/dev/null 2>&1; then
      die "$n 실행 중 — 먼저 종료(⌘Q) 후 재시도"
    fi
  done
}

# --- 엔타이틀먼트 / 서명 ---------------------------------------------------

# dump_entitlements BIN OUT → 현재 서명의 엔타이틀먼트(XML). 서명/엔타이틀먼트가 없으면 1.
dump_entitlements() {
  : > "$2"
  /usr/bin/codesign -d --entitlements - --xml "$1" > "$2" 2>/dev/null || true
  [ -s "$2" ] && /usr/bin/plutil -lint -s "$2" >/dev/null 2>&1
}

write_empty_plist() {
  cat > "$1" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
EOF
}

# JIT/디버그 키를 bool true 로 (기존 값/타입과 무관하게 Delete → Add). 키에 점이 있어 작은따옴표 필수.
set_jit_keys() {
  local key
  for key in $GAKU_JIT_KEYS; do
    /usr/libexec/PlistBuddy -c "Delete ':$key'" "$1" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Add ':$key' bool true" "$1" >/dev/null
    [ "$(plist_get "$1" "$key")" = true ] || die "엔타이틀먼트 설정 실패: $key"
  done
}

del_jit_keys() {
  local key
  for key in $GAKU_JIT_KEYS; do
    /usr/libexec/PlistBuddy -c "Delete ':$key'" "$1" >/dev/null 2>&1 || true
    if plist_get "$1" "$key" >/dev/null; then die "엔타이틀먼트 제거 실패: $key"; fi
  done
}

# ensure_app_entitlements BIN ENT — 서명 직전 ENT 점검.
# .orig 에 있는 app-sandbox/sbpl 이 ENT 에 없으면 ENT 를 .orig 의 엔타이틀먼트로 다시 구성.
# 그래도 app-sandbox 가 없는데 PlayTools 를 로드하는(PlayCover 설치) 앱이면 중단.
ensure_app_entitlements() {
  local bin="$1" ent="$2" key tmp lost="" pt
  if [ -f "$bin.orig" ]; then
    tmp=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/gaku-ent-orig.XXXXXX")
    if dump_entitlements "$bin.orig" "$tmp"; then
      for key in $GAKU_APP_KEYS; do
        if plist_get "$tmp" "$key" >/dev/null && ! plist_get "$ent" "$key" >/dev/null; then lost="$lost $key"; fi
      done
      if [ -n "$lost" ]; then
        warn "현재 서명에 앱 엔타이틀먼트가 빠져 있음 (${lost# }) — $bin.orig 의 엔타이틀먼트로 다시 구성"
        cp "$tmp" "$ent"
      fi
    fi
    rm -f "$tmp"
  fi
  if ! plist_get "$ent" com.apple.security.app-sandbox >/dev/null; then
    pt=$(count_loads "$bin" PlayTools)
    [ "$pt" = 0 ] ||
      die "PlayCover 설치 앱(PlayTools 로드)인데 서명할 엔타이틀먼트에 app-sandbox 가 없음 — 이대로면 샌드박스가 풀림. $bin.orig 확인 또는 IPA 재임포트"
    warn "엔타이틀먼트에 app-sandbox 없음 (PlayCover 외 런타임으로 보고 계속)"
  fi
}

has_jit() {  # has_jit BIN
  local tmp rc=1
  tmp=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/gaku-ent-check.XXXXXX")
  if dump_entitlements "$1" "$tmp" &&
     [ "$(plist_get "$tmp" com.apple.security.cs.allow-jit)" = true ]; then rc=0; fi
  rm -f "$tmp"
  return "$rc"
}

# Frameworks/*.framework, PlugIns/* 재서명 (기존 엔타이틀먼트/플래그 유지). 실패는 경고만.
resign_nested() {
  local app="$1" fw fwname pi
  for fw in "$app/Frameworks"/*.framework; do
    [ -d "$fw" ] || continue
    fwname=$(basename "$fw" .framework)
    if [ -f "$fw/$fwname" ]; then
      /usr/bin/codesign --force --sign - --preserve-metadata=entitlements,flags "$fw/$fwname" 2>/dev/null ||
        warn "서명 실패: $fw/$fwname"
    fi
    /usr/bin/codesign --force --sign - --preserve-metadata=entitlements,flags "$fw" 2>/dev/null ||
      warn "서명 실패: $fw"
  done
  for pi in "$app/PlugIns"/*; do
    [ -e "$pi" ] || continue
    /usr/bin/codesign --force --sign - --preserve-metadata=entitlements,flags "$pi" 2>/dev/null ||
      warn "서명 실패: $pi"
  done
}

sign_main() {  # sign_main APP BIN ENT — 메인 바이너리 → 앱 번들 순
  /usr/bin/codesign --force --sign - --entitlements "$3" "$2" || die "서명 실패: $2"
  /usr/bin/codesign --force --sign - --entitlements "$3" "$1" || die "서명 실패: $1"
  local out
  out=$(/usr/bin/codesign --verify --verbose "$1" 2>&1) || die "서명 검증 실패: $out"
}

# --- login-persistence-poc -------------------------------------------------

# private-backup 위치: GAKU_POC_BACKUP_DIR > tools/…/private-backup > docs/…/private-backup
# (2026-09-20 실제 설치에 쓰인 before-compat 백업은 docs/login-persistence-poc/private-backup 에 있음)
poc_backup_dir() {
  local d
  if [ -n "${GAKU_POC_BACKUP_DIR:-}" ]; then echo "${GAKU_POC_BACKUP_DIR%/}"; return 0; fi
  for d in "$GAKU_TOOLS/login-persistence-poc/private-backup" "$GAKU_ROOT/docs/login-persistence-poc/private-backup"; do
    if [ -f "$d/idolmaster_gakuen.before-compat" ]; then echo "$d"; return 0; fi
  done
  echo "$GAKU_TOOLS/login-persistence-poc/private-backup"
}
