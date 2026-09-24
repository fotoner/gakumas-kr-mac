# gakumas-kr-mac

macOS에 IPA로 설치된 학원 아이돌마스터(学園アイドルマスター, Gakuen Idolmaster)를 한국어로 플레이할 수 있게 해주는 패치 프로젝트. 공개 문서는 `README.md`, 기여자 가이드는 이 파일, `docs/`는 gitignored 로컬 작업 노트.

## 이 프로젝트가 하는 일

iOS용 `GakumasLocalifyIOS_KR.dylib`(한국 커뮤니티 배포본)을 학원마스 앱 번들에 주입 + 재서명. Dobby hook 엔진을 함께 번들해서 Mac Catalyst 환경에서도 게임 내 텍스트를 한국어로 치환.

주입·재서명 자체는 다른 IPA 런타임에도 적용되지만, `make run` preflight가 PlayCover 앱 설정·PlayChain DB를 요구하므로 **현재 PlayCover 전용**. 앱 번들은 `find_app`이 자동 탐색, 그 밖의 위치는 `APP=<.app 경로>`.

선택 기능 `tools/login-persistence-poc/`: PlayChain(PlayCover의 키체인 대체 SQLite)에서 재실행 시 로그인이 풀리는 문제를 게임 전용 shim(`GakuPlayChainCompat.dylib`) + `make run` preflight로 보정.

## 디렉토리 구조

```
gakumas-kr-mac/
├── CLAUDE.md / README.md
├── Makefile                       ← help / setup / patch / run / revert / logs / verify / playchain-status / clean / clean-all
├── docs/                          ← 로컬 작업 노트 (gitignored)
├── ios/
│   └── GakumasLocalifyIOS_KR.dylib ← 한국어 dylib (patch 입력, 저장소 미포함)
├── tools/
│   ├── lib/common.sh              ← 공용 헬퍼 (find_app, ensure_devtools, count_loads, 서명/엔타이틀먼트)
│   ├── macho-loads.py             ← otool 없이 LC_LOAD_DYLIB 목록/개수 (파싱 실패 = exit 2)
│   ├── patch.sh                   ← 통합 패치
│   ├── resign-with-jit.sh         ← make run: 주입 검증 → preflight → JIT 재서명 → 실행
│   ├── revert.sh                  ← 패치 되돌리기
│   ├── watch-logs.sh              ← 로그 스트리밍
│   ├── localizationConfig.json    ← 게임 동작 플래그 (dumpText: false 유지)
│   ├── login-persistence-poc/     ← 로그인 유지 수정 (선택)
│   │   ├── src/                   ← shim(PlayChainCompat.m) + 테스트 소스
│   │   ├── build-and-test.py      ← PlayTools f2bfbd7 + 가짜 DB 테스트 + dylib 빌드
│   │   ├── apply.sh / rollback.sh ← 설치 / 제거
│   │   └── playchain-recover.py   ← PlayChain DB check / dedup / preflight (해시만 출력)
│   ├── insert_dylib               ← [make setup 으로 빌드, .gitignore]
│   └── libdobby.dylib             ← [make setup 으로 빌드, .gitignore]
└── vendor/                        ← [make setup 으로 clone, .gitignore]
    ├── Dobby/                     ← https://github.com/jmpews/Dobby @ 5dfc854
    └── insert_dylib/              ← https://github.com/Tyilo/insert_dylib
```

### 의존성 관리 (Makefile)

바이너리를 레포에 포함하지 않고 **`make setup`으로 clone + 빌드** (cmake 있으면 3-4초). 버전은 Makefile에 pin: **Dobby** `5dfc854` (2026-04-22 Day 0 검증), **insert_dylib** `master` (Tyilo 포크). 재빌드는 `make clean && make setup`.

Day 0에 비교한 레퍼런스(Android APK, DMM `version.dll`)는 삭제함 — 필요하면 [chinosk6/gakuen-imas-localify releases](https://github.com/chinosk6/gakuen-imas-localify/releases)에서 재획득. Android=ShadowHook, Windows=MinHook을 정적 링크하고 iOS 빌드만 hook 엔진이 없어 Mac은 Dobby를 별도 번들.

## 빠른 시작

전제: Apple Silicon, macOS 14+ (테스트: 26 Tahoe, 27), PlayCover 3.0+ 에 학원마스 IPA 임포트, `cmake`.

- 앱 탐색: `/Applications`, `~/Applications`, PlayCover 컨테이너 중 **정확히 1개**여야 함 (0개/여러 개면 멈춤 → `APP=` 지정). PlayCover 별칭(`~/Applications/PlayCover/*.app`, 심볼릭 링크 묶음)은 거부.

```bash
make setup                                  # 최초 1회
make patch                                  # dylib 주입 + 재서명
bash tools/login-persistence-poc/apply.sh   # (선택) 로그인 유지 수정
make run                                    # preflight + JIT 재서명 후 실행 (= bash tools/resign-with-jit.sh)
make verify                                 # 서명 + 주입 dylib 로드 커맨드 수(각 1) + JIT 키
make playchain-status                       # 로그인 DB 읽기 전용 확인
make logs                                   # 로그 스트리밍
make revert                                 # 원복
```

### 게임 업데이트 대응

1. 게임·PlayCover 종료 → PlayCover로 새 IPA 임포트 (Play는 누르지 말 것). 탐색 경로에 이전 버전 번들이 남아 있으면 `find_app`이 멈춤 → 경로 밖으로 옮기거나 `APP=`로 새 번들 지정.
2. Unity 버전이 올랐으면 한국어 dylib을 새 게임 버전 지원 upstream 빌드로 교체 (상태 2026-06-14 참고).
3. `make patch` → 로그인 수정: `apply.sh`·`rollback.sh`의 `EXPECT_VERSION="3.4.0 (89)"`을 새 버전으로 바꾸고, `{tools,docs}/login-persistence-poc/private-backup/idolmaster_gakuen.before-compat`을 `….before-compat.<이전 버전>`으로 이름 변경(삭제 금지) 후 `apply.sh`. 그대로 두면 apply가 이전 버전 백업을 유지해 `rollback.sh`가 옛 바이너리를 새 번들에 복원함.
4. `make playchain-status`로 확인 후 `make run`.

PlayCover 업데이트로 preflight가 PlayTools 경고를 내면: `build-and-test.py`는 f2bfbd7 소스만 받으므로 재실행은 검증이 아님. 새 PlayTools 커밋으로 `expected`(+ README clone 커밋)를 바꿔 통과하면 `playchain-recover.py`의 `PLAYTOOLS_SHA8` 갱신, 안 되면 `rollback.sh`.

## 핵심 작업 원칙

- **실행은 `make run`(또는 `bash tools/resign-with-jit.sh`)만. PlayCover Play 버튼·KeyCover 'Lock all' 금지**: KeyCover가 오래된 `.keyCover`를 PlayChain DB 위로 복원하거나 DB를 잠가 로그인이 롤백되고, PlayCover가 앱을 재서명함. 주입 dylib 로드 확인: `vmmap <pid> | grep -iE 'gakumas|dobby|GakuPlayChain'`.
- **preflight** (`playchain-recover.py preflight`, exit 3 = 실행 거부): `.keyCover`·DB 이상·PlayCover 실행 중이면 거부 (로그인 항목이 아직 없는 첫 실행은 `GAKU_ALLOW_EMPTY_CHAIN=1 make run`), 통과 시 `~/Library/Application Support/gakumas-kr-mac/playchain-backups`에 백업 후 같은 계정 중복 정리.
- **게임 프로세스 안에서 PlayChain 행 삭제 금지**: shim은 SQL 없이 중복을 경고만. 정리는 게임 종료 후 `playchain-recover.py`로만, 조사 시 DB는 `sqlite3` URI `mode=ro`.
- **비밀값 출력 금지**: 토큰·uid·이메일·`v_Data` 대신 sha256 앞 8자리·개수·시각만.
- **재서명은 JIT/디버그 키만 넣고 뺄 것**: `app-sandbox` 등 앱 고유 엔타이틀먼트는 유지 (revert가 전부 지웠던 적 있음).
- **`insert_dylib`은 LC_CODE_SIGNATURE를 스트립함** → 재서명 필수.
- **`codesign --deep` 사용하지 말 것** (macOS 11+ deprecated). 프레임워크별로 개별 서명.
- **`plutil -insert`는 키에 점(`.`)이 있으면 경로로 해석해 실패** → `/usr/libexec/PlistBuddy`에 키를 작은따옴표로 감싸서 사용.
- **원본 백업(`.orig`)을 절대 지우지 말 것** — Revert 불가능해짐.
- **Xcode 라이선스 미동의 → `make`·`xcrun`·`otool`·`vtool`이 exit 69**: `DEVELOPER_DIR=/Library/Developer/CommandLineTools` (스크립트는 `ensure_devtools`가 처리), 로드 커맨드 확인은 `tools/macho-loads.py`.
- **PATH에 GNU coreutils가 먼저 있음** → 스크립트는 `/usr/bin/mktemp`, `/usr/bin/stat`을 명시 호출 (임시 파일은 고정 경로 말고 `mktemp`).

## 참고 자료

- [chinosk6/gakuen-imas-localify](https://github.com/chinosk6/gakuen-imas-localify) — 원본 dylib 제작자 (소스는 DMCA로 takedown, 릴리스는 접근 가능)
- [jmpews/Dobby](https://github.com/jmpews/Dobby) — hook 엔진 (Apache-2.0)
- [PlayCover/PlayTools @ f2bfbd7](https://github.com/PlayCover/PlayTools/tree/f2bfbd76ff55f4737c959fa2eac07f9ada2e6d7e/PlayTools/MysticRunes) — PlayChain 소스 (AGPL-3.0, 테스트용으로만 로컬 clone)
- pinisok/GakumasTranslationDataKorTest — 한국어 번역 데이터 (dylib이 런타임에 자동 다운로드)
- [디시 학원마스 갤러리 한글패치 공지](https://gall.dcinside.com/mgallery/board/view/?id=gakumas&no=86599)

## 상태

- **Day 0 스파이크 통과** (2026-04-22): macOS 26 Tahoe + PlayCover + Dobby 주입으로 게임 내 한국어 표시 확인
- **게임 업데이트 대응** (2026-06-14): Unity 6대 빌드로 갱신되며 기존 dylib이 `StartInjectFunctions`에서 SIGSEGV → 새 게임 버전 지원 upstream 빌드로 교체해 해결 (1회성 Metal 텍스처 assert는 재실행 시 해소)
- **로그인 풀림 원인 확정 + 수정** (2026-09-24): PlayChain이 Firebase 항목(`agrp` NULL → PK 미적용)에 `errSecDuplicateItem`을 주지 않아 저장마다 행이 쌓이고 조회는 가장 오래된 행을 반환, 여기에 KeyCover unlock이 오래된 스냅샷(가장 오래된 행이 게스트)을 복원. 수정: shim v2(행이 1개면 `errSecDuplicateItem` → Firebase가 update) + `make run` preflight(KeyCover/DB 점검·백업·중복 정리).
- **Phase 1 대기 중**: SwiftUI Drop Zone 앱으로 `tools/patch.sh`를 GUI 래핑

## 라이선스 / 법적

- 이 프로젝트 자체: 게임 바이너리/에셋 재배포 없음. 사용자가 이미 IPA로 설치한 로컬 번들에 dylib 주입 + 재서명만 수행.
- dylib/번역 데이터: 원작자(chinosk6/pinisok) 공개 배포처에서 런타임 다운로드. 별도 재배포 안 함.
- Dobby: Apache-2.0. 재배포 시 라이선스 파일 포함. PlayTools(AGPL-3.0)는 테스트용 로컬 clone만, 저장소 미포함.
