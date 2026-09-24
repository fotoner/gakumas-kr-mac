# gakumas-kr-mac

macOS에 IPA로 설치된 학원 아이돌마스터(学園アイドルマスター, Gakuen Idolmaster)를 한국어로 플레이할 수 있게 해주는 패치 프로젝트.

## docs/

Gitignored 로컬 작업 노트. 공개 문서는 `README.md`, 기여자 가이드는 이 파일.

## 이 프로젝트가 하는 일

iOS용 `GakumasLocalifyIOS_KR.dylib`(한국 커뮤니티 배포본)을 학원마스 앱 번들에 주입 + 재서명. Dobby hook 엔진을 함께 번들해서 Mac Catalyst 환경에서도 게임 내 텍스트를 한국어로 치환.

IPA 기반 iOS-on-Mac 런타임이면 원리적으로 작동 가능 (PlayCover 외에도 LiveContainer 기반 Mac 런타임 등). 현재 **검증된 환경은 PlayCover**. 앱 번들은 `tools/lib/common.sh`의 `find_app`이 자동 탐색하고, 그 밖의 위치는 `APP=<.app 경로>`로 지정.

선택 기능: `tools/login-persistence-poc/` — PlayCover PlayChain(키체인 대체 SQLite)에서 재실행 시 로그인이 풀리는 문제를 게임 전용 shim(`GakuPlayChainCompat.dylib`) + 실행 전 preflight로 보정.

## 디렉토리 구조

```
gakumas-kr-mac/
├── CLAUDE.md                      ← 이 파일 (프로젝트 개요 + 작업 가이드)
├── Makefile                       ← make setup / patch / run / revert / verify
├── .gitignore                     ← 빌드 산물 + vendor/ 제외
├── docs/                          ← 로컬 개발 작업 노트 (gitignored, 공개 안 함)
├── ios/
│   └── GakumasLocalifyIOS_KR.dylib ← 한국어 dylib (patch 입력)
├── tools/
│   ├── lib/common.sh              ← 공용 헬퍼 (find_app, count_loads, 서명/엔타이틀먼트, ensure_devtools)
│   ├── patch.sh                   ← 8단계 통합 패치
│   ├── resign-with-jit.sh         ← make run: dylib 검증 → PlayChain preflight → JIT 재서명 → 실행
│   ├── revert.sh                  ← 패치 되돌리기 (주입 dylib 3개 제거, JIT 키 5개 제거)
│   ├── watch-logs.sh              ← 로그 스트리밍
│   ├── macho-loads.py             ← otool 없이 LC_LOAD_DYLIB 목록/개수/LC_UUID (파싱 실패 = exit 2)
│   ├── localizationConfig.json    ← 게임 동작 플래그 (enabled 등, dumpText: false)
│   ├── login-persistence-poc/     ← 로그인 유지 수정 (선택)
│   │   ├── src/PlayChainCompat.m  ← shim v2 (GakuPlayChainCompat.dylib)
│   │   ├── build-and-test.py      ← PlayTools f2bfbd7 fixture + 가짜 DB 테스트 + dylib 빌드
│   │   ├── apply.sh / rollback.sh ← 설치(업그레이드 시 dylib만 교체) / 제거
│   │   └── playchain-recover.py   ← PlayChain DB check / dedup / preflight (해시만 출력)
│   ├── insert_dylib               ← [make setup 으로 빌드, .gitignore]
│   └── libdobby.dylib             ← [make setup 으로 빌드, .gitignore]
└── vendor/                        ← [make setup 으로 clone, .gitignore]
    ├── Dobby/                     ← https://github.com/jmpews/Dobby @ 5dfc854
    └── insert_dylib/              ← https://github.com/Tyilo/insert_dylib
```

### 의존성 관리 (Makefile)

바이너리를 레포에 포함하지 않고 **`make setup`으로 clone + 빌드**. 버전은 Makefile에 commit SHA로 pin:

- **Dobby**: `5dfc854` (2026-04-22 Day 0 스파이크 검증)
- **insert_dylib**: `master` (Tyilo 포크, 안정)

최초 setup 시간: 약 **3-4초** (cmake 있으면). 재빌드는 `make clean && make setup`.

### 삭제된 레퍼런스 (Day 0 검증 완료, 필요 시 재획득)

- **Android APK** (`GakumasLocalify_v3.2.0k.apk`): [chinosk6/gakuen-imas-localify releases](https://github.com/chinosk6/gakuen-imas-localify/releases)
- **DMM version.dll**: 같은 릴리스의 `DMM_GakumasLocalify_v3.2.0.zip`
- **검증 결과**: Android=ShadowHook, Windows=MinHook 정적 링크 번들로 hook 엔진 포함. iOS 빌드만 미포함이라 Mac에서 Dobby 별도 번들 필요.

## 빠른 시작

### 전제
- Apple Silicon Mac, macOS 14+ (테스트: macOS 26 Tahoe, macOS 27)
- IPA 기반 iOS 앱 런타임 설치 — **검증은 PlayCover 3.0+** (`/Applications/PlayCover.app`)
- 학원마스 IPA 임포트 완료. 앱 위치 자동 탐색 순서: `/Applications`, `~/Applications`, PlayCover 컨테이너
  - 이 머신의 정식 위치: **`/Applications/jp.co.bandainamcoent.BNEI0421.app`** (PlayCover 목록에 안 보이게 둔 것, 의도됨)
  - PlayCover 임포트 직후 위치: `~/Library/Containers/io.playcover.PlayCover/Applications/jp.co.bandainamcoent.BNEI0421.app`
  - 후보가 0개/여러 개면 모든 스크립트가 멈춤 → `APP=<.app 경로>` 지정
  - `~/Applications/PlayCover/学マス.app`은 PlayCover 별칭(심볼릭 링크 묶음) — **절대 APP로 쓰지 말 것** (`find_app`이 거부)
- `cmake` (없으면 `brew install cmake`)
- **Xcode 라이선스 미동의 시** `/usr/bin/make`·`xcrun` 계열이 exit 69 → `DEVELOPER_DIR=/Library/Developer/CommandLineTools make run` 또는 `bash tools/resign-with-jit.sh`. 스크립트 내부는 `ensure_devtools`가 CLT로 자동 우회. PATH의 GNU coreutils 때문에 스크립트는 `/usr/bin/stat`, `/usr/bin/mktemp`를 명시 호출

### 최초 1회: 의존성 빌드
```bash
make setup
```
Dobby와 insert_dylib를 clone + 빌드. 약 3-4초.

### 패치 적용
```bash
make patch
```

### 실행 (PlayCover 우회 — preflight + JIT 재서명 후 직접 실행)
```bash
make run                        # = bash tools/resign-with-jit.sh
```

### 상태 확인
```bash
make verify                     # 서명 + 주입 dylib 로드 커맨드 수(정상: 각 1) + JIT 키
make playchain-status           # 로그인 DB 읽기 전용 확인 (= playchain-recover.py check)
```

### 되돌리기
```bash
make revert
```

### 로그 스트리밍
```bash
make logs
```

### 전체 워크플로우
```
make setup    (최초 1회)
make patch    ← 학원마스 번들 수정
bash tools/login-persistence-poc/apply.sh   ← (선택) 로그인 유지 수정
make run      ← 게임 실행
# 게임 테스트 후 문제 시:
make revert   ← 원복
```

### 게임 업데이트 대응 순서
1. 게임 종료. PlayCover에서 새 IPA 임포트 → 새 번들은 PlayCover 컨테이너에 생김 → `/Applications`의 이전 번들과 **두 개**가 되어 스크립트가 멈춤
2. 이전 `/Applications` 번들을 지우고 새 번들을 `/Applications`로 옮김 (당장은 `APP=<새 번들>` 지정도 가능). 이전 빌드의 `.orig`는 새 빌드에 못 씀 (`patch.sh`/`revert.sh`가 LC_UUID로 거부)
3. PlayCover가 띄워도 **Play 누르지 말 것**. 필요하면 한국어 dylib을 새 게임 버전 지원 빌드로 교체 (아래 상태 2026-06-14 참고)
4. `make patch` → `bash tools/login-persistence-poc/apply.sh`
   - apply/rollback은 버전 게이트(`EXPECT_VERSION`, 현재 3.4.0 (89)) → 새 버전은 `build-and-test.py` 재검증 후 갱신
   - 기존 `private-backup/`의 before-compat는 이전 빌드용이라 거부됨 → `GAKU_POC_BACKUP_DIR`로 새 위치 지정
5. 첫 실행 전 `make playchain-status`로 `.keyCover` 유무·중복 확인 → `make run` (preflight가 먼저 돌고 거부 시 실행 안 함)

## 핵심 작업 원칙

- **실행은 `make run` / `bash tools/resign-with-jit.sh`만. PlayCover Play 버튼, KeyCover 'Lock all' 금지**: macOS 27에서는 PlayCover의 일반 서명(hardened runtime 없음)으로도 주입 dylib 3개가 모두 로드됨 — 예전 "Play 버튼은 dylib을 조용히 스킵" 설명은 더 이상 맞지 않음. 실제 위험은 **KeyCover**(활성 유지가 사용자 정책): Play 시 unlock이 오래된 `<bundle>.keyCover`를 PlayChain `.db` 위로 복호화 → 로그인이 과거 계정으로 롤백, 정상 종료 시 lock이 `.db`를 `.keyCover`로 암호화하고 `.db` 삭제. PlayCover가 앱을 재서명하는 것도 문제. 그래서 번들을 `/Applications`에 둬 PlayCover에서 안 보이게 함. 로드 확인: `vmmap <pid> | grep -iE 'gakumas|dobby|GakuPlayChain'`.
- **`make run` = 검증 → preflight → 재서명 → `open`**: 게임 실행 중이면 거부, 주입 dylib 로드 커맨드가 각 1개 + `Frameworks`에 실파일인지 확인, `playchain-recover.py preflight` 통과 시에만 JIT/디버그 키 5개를 매번 새로 넣어 재서명(`app-sandbox` 등 앱 고유 키 유지).
- **preflight 규칙** (exit 3 = 실행 거부, 거부 경로는 아무것도 쓰지 않음): `.keyCover` 존재(삭제 말고 백업 폴더로 이동 — 명령 출력됨), `.db` 없음/0바이트(`GAKU_ALLOW_EMPTY_CHAIN=1`로만 허용), `-journal`/`-wal` 잔존, 무결성 실패, `playChain` 설정 꺼짐, 로그인 계정 2개 이상 혼재, 직전 실행과 계정이 다름(`GAKU_ACCEPT_ACCOUNT_CHANGE=1`로 허용, 게스트에서 바뀌는 건 자동 허용). 통과 시 `~/Library/Application Support/gakumas-kr-mac/playchain-backups`에 백업(최근 10개 순환 + 계정별 `account-<uid해시>.db` + `last-launch.json`) 후 같은 계정 중복은 최신 행만, 게스트+로그인 계정 1개면 로그인 계정만 남김. PlayTools 해시가 검증 빌드(`548eaa72`)와 다르면 경고.
- **게임 프로세스 안에서 PlayChain 행 삭제 금지**: shim v2는 SQL 없음, 중복은 경고만. 정리는 게임 종료 상태에서 `playchain-recover.py`(preflight/dedup)로만. 조사할 때 DB/PlayCover 설정은 읽기 전용(`sqlite3` URI `mode=ro`).
- **로그/출력에 비밀값 금지**: 토큰·uid·이메일·`v_Data`는 출력하지 않음. sha256 앞 8자리, 개수, 길이, 시각만 (`playchain-recover.py`와 shim 로그가 이 규칙을 따름).
- **`insert_dylib`은 LC_CODE_SIGNATURE를 스트립함** → 재서명 필수.
- **`codesign --deep` 사용하지 말 것** (macOS 11+ deprecated). 프레임워크별로 개별 서명.
- **`plutil -insert`는 키에 점(`.`)이 있으면 경로로 해석해 실패** → `/usr/libexec/PlistBuddy`에 키를 작은따옴표로 감싸서 사용.
- **원본 백업(`.orig`)을 절대 지우지 말 것** — Revert 불가능해짐. `patch.sh`는 이미 패치된 바이너리로 `.orig`를 만들지 않고, 빌드가 다른 `.orig`(LC_UUID 불일치)는 거부.

## 참고 자료

- [chinosk6/gakuen-imas-localify](https://github.com/chinosk6/gakuen-imas-localify) — 원본 dylib 제작자 (소스는 DMCA로 takedown, 릴리스는 접근 가능)
- [jmpews/Dobby](https://github.com/jmpews/Dobby) — hook 엔진 (Apache-2.0)
- [PlayCover/PlayTools @ f2bfbd7](https://github.com/PlayCover/PlayTools/tree/f2bfbd76ff55f4737c959fa2eac07f9ada2e6d7e/PlayTools/MysticRunes) — PlayChain 소스 (`PlayedApple*.swift`, AGPL-3.0, 테스트용으로만 로컬 clone)
- pinisok/GakumasTranslationDataKorTest — 한국어 번역 데이터 (dylib이 런타임에 자동 다운로드)
- [디시 학원마스 갤러리 한글패치 공지](https://gall.dcinside.com/mgallery/board/view/?id=gakumas&no=86599)

## 상태

- **Day 0 스파이크 통과** (2026-04-22 02:00): macOS 26 Tahoe + PlayCover + Dobby 주입으로 게임 내 한국어 표시 확인
- **게임 업데이트 대응** (2026-06-14): 게임이 Unity 6대 빌드로 갱신되며 기존 dylib이 후킹 단계(`StartInjectFunctions`)에서 SIGSEGV. 게임이 엔진(Unity) 버전을 올리면 dylib도 해당 게임 버전을 지원하는 상위 upstream 빌드로 교체해야 함 — 교체 후 정상 작동 확인. (이후 1회성 Metal 텍스처 assert는 셰이더 캐시 워밍업으로 재실행 시 해소)
- **로그인 풀림 원인 확정 + 수정** (2026-09-24): PlayChain `genp`의 PK가 `(agrp, acct, svce)`인데 Firebase가 access group을 넣지 않아 `agrp=NULL` → SQLite가 PK를 강제하지 않아 `SecItemAdd`가 `errSecDuplicateItem` 없이 매번 새 행 추가 → 로그인/토큰 갱신마다 행 누적. 조회는 `ORDER BY` 없이 첫 행(가장 오래된 행)을 반환 → 재실행 시 과거 계정(게스트)이 복원됨. v1 shim(배열 반환)은 조회 오류만 고쳐 누적은 그대로였음. 2026-09-21에는 PlayCover Play로 KeyCover가 오래된 `.keyCover`를 `.db` 위로 복호화해 롤백이 겹침. 수정: shim v2(행이 정확히 1개면 add → `errSecDuplicateItem` → Firebase가 update, 2개 이상이면 추가+경고, delete `errSecIO` 보정, 조회 항목 중복 제거) + `make run` preflight(KeyCover/DB 없음 거부, 같은 계정 중복 자동 정리, 백업 순환) + 번들 `/Applications` 이동. `build-and-test.py` 76/76, 스크립트는 가짜 번들/DB로 검증. 작성 시점 실제 게임에는 v1 설치 상태 — v2는 게임 종료 후 `apply.sh`(업그레이드 모드: dylib만 교체)로 적용
- **Phase 1 대기 중**: SwiftUI Drop Zone 앱으로 `tools/patch.sh`를 GUI 래핑

## 라이선스 / 법적

- 이 프로젝트 자체: 게임 바이너리/에셋 재배포 없음. 사용자가 이미 IPA로 설치한 로컬 번들에 dylib 주입 + 재서명만 수행.
- dylib/번역 데이터: 원작자(chinosk6/pinisok) 공개 배포처에서 런타임 다운로드. 별도 재배포 안 함.
- Dobby: Apache-2.0. 재배포 시 라이선스 파일 포함.
