# gakumas-kr-mac

macOS에 IPA로 설치된 학원 아이돌마스터(学園アイドルマスター, Gakuen Idolmaster)를 한국어로 플레이할 수 있게 해주는 패치 프로젝트.

## docs/

Gitignored 로컬 작업 노트. 공개 문서는 `README.md`, 기여자 가이드는 이 파일.

## 이 프로젝트가 하는 일

iOS용 `GakumasLocalifyIOS_KR.dylib`(한국 커뮤니티 배포본)을 학원마스 앱 번들에 주입 + 재서명. Dobby hook 엔진을 함께 번들해서 Mac Catalyst 환경에서도 게임 내 텍스트를 한국어로 치환.

IPA 기반 iOS-on-Mac 런타임이면 원리적으로 작동 가능 (PlayCover 외에도 LiveContainer 기반 Mac 런타임 등). 현재 **검증된 환경은 PlayCover**이며, 다른 런타임은 IPA 번들 경로가 다르므로 `tools/patch.sh`의 `APP` 변수를 해당 런타임 경로로 지정해서 사용 가능.

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
│   ├── patch.sh                   ← 10단계 통합 패치
│   ├── resign-with-jit.sh         ← JIT 엔타이틀먼트 재서명 + 실행
│   ├── revert.sh                  ← 패치 되돌리기
│   ├── watch-logs.sh              ← 로그 스트리밍
│   ├── localizationConfig.json    ← 게임 동작 플래그 (enabled 등)
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
- Apple Silicon Mac, macOS 14+ (테스트: macOS 26 Tahoe)
- IPA 기반 iOS 앱 런타임 설치 — **검증은 PlayCover 3.0+** (`/Applications/PlayCover.app`)
- 학원마스 IPA 임포트 완료
  - PlayCover 기준 경로: `~/Library/Containers/io.playcover.PlayCover/Applications/jp.co.bandainamcoent.BNEI0421.app`
  - 다른 런타임이면 `tools/patch.sh`의 `APP` 변수를 해당 경로로 수정
- `cmake` (없으면 `brew install cmake`)

### 최초 1회: 의존성 빌드
```bash
make setup
```
Dobby와 insert_dylib를 clone + 빌드. 약 3-4초.

### 패치 적용
```bash
make patch
```

### 실행 (PlayCover UI 우회 — JIT 엔타이틀먼트 유지됨)
```bash
make run
```

### 상태 확인
```bash
make verify
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
make run      ← 게임 실행
# 게임 테스트 후 문제 시:
make revert   ← 원복
```

## 핵심 작업 원칙

- **PlayCover UI의 Play 버튼 지양**: 실행 시 재서명 덮어쓸 가능성. `open "$APP"`으로 직접 실행 권장.
- **`insert_dylib`은 LC_CODE_SIGNATURE를 스트립함** → 재서명 필수.
- **`codesign --deep` 사용하지 말 것** (macOS 11+ deprecated). 프레임워크별로 개별 서명.
- **`plutil -insert`는 키에 점(`.`)이 있으면 경로로 해석해 실패** → `/usr/libexec/PlistBuddy`에 키를 작은따옴표로 감싸서 사용.
- **원본 백업(`.orig`)을 절대 지우지 말 것** — Revert 불가능해짐.

## 참고 자료

- [chinosk6/gakuen-imas-localify](https://github.com/chinosk6/gakuen-imas-localify) — 원본 dylib 제작자 (소스는 DMCA로 takedown, 릴리스는 접근 가능)
- [jmpews/Dobby](https://github.com/jmpews/Dobby) — hook 엔진 (Apache-2.0)
- pinisok/GakumasTranslationDataKorTest — 한국어 번역 데이터 (dylib이 런타임에 자동 다운로드)
- [디시 학원마스 갤러리 한글패치 공지](https://gall.dcinside.com/mgallery/board/view/?id=gakumas&no=86599)

## 상태

- **Day 0 스파이크 통과** (2026-04-22 02:00): macOS 26 Tahoe + PlayCover + Dobby 주입으로 게임 내 한국어 표시 확인
- **Phase 1 대기 중**: SwiftUI Drop Zone 앱으로 `tools/patch.sh`를 GUI 래핑

## 라이선스 / 법적

- 이 프로젝트 자체: 게임 바이너리/에셋 재배포 없음. 사용자가 이미 IPA로 설치한 로컬 번들에 dylib 주입 + 재서명만 수행.
- dylib/번역 데이터: 원작자(chinosk6/pinisok) 공개 배포처에서 런타임 다운로드. 별도 재배포 안 함.
- Dobby: Apache-2.0. 재배포 시 라이선스 파일 포함.
