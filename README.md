# gakumas-kr-mac

> Mac에서 학원 아이돌마스터(学園アイドルマスター) 한국어 패치를 자동 적용하는 도구

PlayCover 등 **IPA로 iOS 앱을 실행하는 Mac 런타임**에서 학원마스를 한국어로 플레이하게 해줍니다. Mac 환경에 맞게 플랫폼 변환 + 주입 + 재서명까지 수행.

## 요구사항

- Apple Silicon Mac, macOS 14+ (Sonoma 이상, **macOS 26 Tahoe·macOS 27 검증 완료**)
- IPA로 학원마스가 설치된 Mac 런타임
  - **검증 환경**: [PlayCover](https://playcover.io) 3.0+
  - 앱 위치는 `/Applications`, `~/Applications`, PlayCover 컨테이너에서 자동으로 찾습니다. 없거나 여러 개면 `make patch APP=<.app 경로>`처럼 지정
  - 다른 IPA 런타임 (LiveContainer 등)도 원리적으로 가능 — `APP=<.app 경로>`로 해당 번들 지정
- [`cmake`](https://cmake.org/) (없으면 `brew install cmake`)
- `ios/GakumasLocalifyIOS_KR.dylib` 파일 — 디시 학원마스 갤러리 한글패치 공지에서 받아 `ios/` 폴더에 놓으세요 (**저장소에 포함돼있지 않음**)

## 사용법

```bash
# 1. clone
git clone https://github.com/fotoner/gakumas-kr-mac.git
cd gakumas-kr-mac

# 2. (수동) dylib 파일을 ios/ 폴더에 배치
#    파일명: ios/GakumasLocalifyIOS_KR.dylib

# 3. 의존성 빌드 (최초 1회, ~3초)
make setup

# 4. 패치 적용
make patch

# 5. 게임 실행 (PlayCover UI 통하지 않고 직접 실행)
make run
```

실행은 항상 `make run`을 사용하세요. PlayCover의 Play 버튼은 앱을 다시 서명하고, KeyCover를 켠 경우 로그인 저장소를 이전 상태로 되돌리거나 잠글 수 있습니다. Xcode 라이선스에 동의하지 않은 상태라 `make`가 exit 69로 실패하면 `DEVELOPER_DIR=/Library/Developer/CommandLineTools make run` 또는 `bash tools/resign-with-jit.sh`로 실행합니다.

### 기타 명령

```bash
make verify   # 현재 패치 상태 확인
make playchain-status  # 로그인 저장소(PlayChain) 상태 확인, 읽기 전용
make logs     # 실행 중 번역 dylib 로그 스트리밍
make revert   # 패치 되돌리기 (원본 복원)
make clean    # 빌드 산물 삭제 (vendor/는 유지)
make help     # 도움말
```

### 재실행 시 로그인이 풀리는 경우: 선택적 PoC

학원마스 3.4.0(build 89) + PlayCover 3.1.0 + PlayTools 1.1.7(`f2bfbd7`)의 PlayChain(PlayCover의 키체인 대체 SQLite 저장소)에서 두 가지 문제를 확인했습니다.

- **조회**: Firebase는 숫자 `kSecMatchLimit=2`로 배열을 요청하지만 PlayChain이 단일 dictionary를 반환해 `ERROR_KEYCHAIN_ERROR`가 발생합니다. [Firebase 조회 코드](https://github.com/firebase/firebase-ios-sdk/blob/85560b48b0ff099ad83fe53d67df3c67fbc2b7a6/FirebaseAuth/Sources/Swift/Storage/AuthKeychainServices.swift#L140), [PlayTools 반환 코드](https://github.com/PlayCover/PlayTools/blob/f2bfbd76ff55f4737c959fa2eac07f9ada2e6d7e/PlayTools/MysticRunes/PlayedApple.swift#L114)
- **저장**: PlayChain 테이블의 primary key는 `(agrp, acct, svce)`인데 Firebase는 access group을 지정하지 않아 `agrp`가 NULL입니다. SQLite는 NULL이 섞인 primary key의 중복을 막지 않으므로 `SecItemAdd`가 `errSecDuplicateItem` 없이 [매번 새 행을 추가](https://github.com/PlayCover/PlayTools/blob/f2bfbd76ff55f4737c959fa2eac07f9ada2e6d7e/PlayTools/MysticRunes/PlayedAppleDB.swift#L88)합니다. 조회는 정렬 없이 첫 행(가장 오래된 행)을 반환하므로 로그인·토큰 갱신이 쌓인 뒤 재실행하면 과거 계정(게스트 등)이 복원됩니다. 삭제는 행을 지우고도 `errSecIO`를 반환합니다.

첫 버전(v1)은 조회만 배열로 보정해 실제 게임에서 조회 오류는 사라졌지만, 행이 계속 쌓여 재실행 시 과거 계정이 복원되는 문제가 남았습니다. [현재 보정 코드(v2)](tools/login-persistence-poc/src/PlayChainCompat.m)는 학원마스 프로세스 안에서만 PlayChain의 조회·추가·삭제를 실제 키체인처럼 응답하게 합니다.

- **조회**: 숫자 제한 요청에 배열을 반환하고, 같은 `(agrp, acct, svce)` 항목은 한 번만(첫 행) 넣습니다.
- **추가**: 같은 항목이 정확히 1행 있으면 `errSecDuplicateItem`을 반환합니다. Firebase는 이어서 `SecItemUpdate`로 그 행을 갱신하므로 행이 늘지 않습니다. 이미 2행 이상이면 어느 행도 덮어쓰지 않고 기존처럼 추가한 뒤 복구 도구 사용을 안내하는 경고를 남깁니다. 같은 실행에서 조회가 "없음"이었던 항목(DB 잠금 등)에 행이 나타난 경우도 덮어쓰지 않고 추가합니다. acct·svce가 문자열이 아닌 항목은 PlayChain 기존 동작을 그대로 씁니다.
- **삭제**: PlayChain이 `errSecIO`를 반환해도 해당 행이 실제로 모두 지워졌으면 성공을 반환합니다. 행이 남아 있으면 원래 오류를 유지합니다.
- SQL을 직접 실행하거나 게임 안에서 행을 지우지 않으며, 공용 PlayTools를 교체하지 않습니다. 기본 `make patch`에는 포함되지 않은 **선택적 PoC**입니다.

이미 쌓인 중복 행은 [복구 도구](tools/login-persistence-poc/playchain-recover.py)가 게임을 종료한 상태에서 정리합니다. 출력에는 sha256 앞 8자리, 행 수, 시각만 표시하고 토큰·사용자 식별자·이메일은 출력하지 않습니다.

- `check`: 읽기 전용. 항목별 행 수, 다음 실행에서 복원될 행, 최신 행, KeyCover·`playChain` 설정·PlayTools 버전 상태 (`make playchain-status`)
- `dedup --keep-uid-hash <해시> [--apply]`: 지정한 계정의 최신 행 하나만 남깁니다. 기본은 미리보기이며 `--apply`는 백업 후 적용합니다.
- `preflight`: `make run`이 실행 직전에 자동 호출합니다. 게임·PlayCover 실행 중, `.keyCover` 존재, DB 없음, 무결성 오류, 여러 로그인 계정 혼재, 직전 실행과 다른 계정이면 실행을 거부하고 해결 명령을 안내합니다. 통과하면 `~/Library/Application Support/gakumas-kr-mac/playchain-backups`에 백업(최근 10개 순환)한 뒤 같은 계정의 중복 행은 최신 행만 남깁니다. 게스트 행과 로그인 계정 하나가 섞인 경우 로그인 계정을 남깁니다.

Apple Silicon Mac, Xcode 또는 Command Line Tools의 macOS SDK, Python 3, Git이 필요합니다. 먼저 위의 `make setup`과 `make patch`를 완료하세요. 아래 명령은 저장소 루트에서 실행합니다.

```bash
# 테스트용 공식 PlayTools 소스 — 고정 커밋, Git 추적 제외
git clone --filter=blob:none --no-checkout https://github.com/PlayCover/PlayTools.git \
  tools/login-persistence-poc/PlayTools-source
git -C tools/login-persistence-poc/PlayTools-source checkout --detach \
  f2bfbd76ff55f4737c959fa2eac07f9ada2e6d7e

# 별도 임시 DB의 가짜 로그인 데이터로 테스트하고 PoC dylib 빌드
python3 tools/login-persistence-poc/build-and-test.py

# 게임을 종료한 상태에서 적용 후 실행 — v1이 이미 설치돼 있으면 dylib만 교체
bash tools/login-persistence-poc/apply.sh
make run   # 실행 직전 preflight 자동 실행

# 로그인 저장소 상태 확인 (읽기 전용)
make playchain-status

# 게임을 종료한 상태에서 PoC만 제거 — 한국어 패치와 로그인 DB 유지
bash tools/login-persistence-poc/rollback.sh
make run
```

테스트는 고정 커밋의 PlayChain 소스를 컴파일한 [재현 코드](tools/login-persistence-poc/src/main.swift)로, 실제 Firebase처럼 access group 없이 저장하는 호출을 매번 별도 프로세스와 임시 DB에서 재현합니다. 첫 로그인, 재실행 사이의 토큰 갱신, 계정 전환, 로그아웃, 기존 중복 행, 게스트 행 뒤의 실제 계정, DB 잠금으로 조회가 "없음"을 반환한 경우, 다른 SDK 방식의 저장, 동시 추가를 다룹니다. v1 방식 대조군으로 행 누적과 과거 계정 복원도 재현합니다. access group이 있는 항목, 비 UTF-8 데이터, 빌드한 Mac Catalyst dylib을 PlayTools 빌드와 함께 로드하는 e2e 검사까지 **76개 검증을 통과**했습니다. 실행 기록은 로컬 `test-results.txt`에 생성되며 공개하지 않습니다.

PoC의 한계와 복구 범위:

- 중복 판정은 acct·svce가 문자열인 generic password만 대상으로 합니다. 다른 형태의 요청은 PlayChain 기존 구현에 전달합니다.
- 이미 쌓인 중복 행은 게임 안에서 지우지 않습니다. 중복이 남아 있는 동안은 추가가 새 행을 만들고 조회는 첫 행을 고르므로, 게임을 종료하고 `make run`(preflight) 또는 `dedup`으로 정리하세요.
- PlayCover KeyCover를 켠 경우 Play 버튼은 오래된 `.keyCover`를 DB 위로 복호화하거나, 종료 시 DB를 암호화하고 삭제할 수 있습니다. preflight는 `.keyCover`가 있으면 실행을 거부하고 파일을 삭제하지 않고 옮기는 명령을 안내합니다.
- 적용·복구 스크립트는 3.4.0(build 89)에 한정합니다. 다른 버전은 추가 검증이 필요합니다. 재임포트하면 PoC는 사라지며, 다른 빌드의 백업은 스크립트가 거부합니다.
- PlayTools가 검증한 빌드와 다르면 preflight가 경고합니다. 이때는 `build-and-test.py`로 다시 검증하세요.
- 적용 직전 실행 파일과 엔타이틀먼트는 로컬 `private-backup/`에 보관하고, 기존 `.orig`는 보존합니다. 업그레이드할 때는 이전 dylib도 함께 보관합니다.
- PoC 진단은 항목 수와 상태 코드만 기록합니다. Firebase 자체 로그 등 원래 게임 로그에는 민감한 값이 포함될 수 있으므로 로그 전체를 공개하지 마세요.

저장소에는 직접 작성한 PoC 소스와 스크립트만 포함합니다. 게임·번역 바이너리, 로그인 백업, 실행 로그, PlayTools 소스 및 빌드 결과는 제외합니다. 테스트 의존성 PlayTools의 라이선스는 [AGPL-3.0](https://github.com/PlayCover/PlayTools/blob/f2bfbd76ff55f4737c959fa2eac07f9ada2e6d7e/LICENSE)이며, 내려받은 소스의 라이선스와 고지를 유지합니다.

## 작동 원리

**기본 원리는 DMM(Windows) / Android 한글패치와 동일합니다.** 학원마스 프로세스에 `GakumasLocalify` dylib을 로드시키고, Unity IL2CPP 함수(TextMeshPro 등 텍스트 출력 루틴)를 **inline hook**으로 가로채서 일본어 → 한국어로 치환하는 방식. 번역 데이터(`localization.json`, `generic.json` 등)는 dylib이 GitHub 릴리스에서 자동 다운로드합니다.

### 플랫폼별 차이


| 플랫폼             | 주입 방식                                     | Hook 엔진                            |
| --------------- | ----------------------------------------- | ---------------------------------- |
| Windows (DMM)   | `version.dll` DLL 하이재킹                    | MinHook (dll에 정적 링크)               |
| Android         | LSPatch로 APK 병합 (`libMarryKotone.so`)     | ShadowHook + xdl (`.so` 번들)        |
| iOS             | LiveContainer / Cydia Substrate가 dylib 로드 | 시스템 tweak 인프라가 제공                  |
| **Mac (이 저장소)** | Mach-O `LC_LOAD_DYLIB` 추가 + adhoc 재서명     | **Dobby (`libdobby.dylib` 별도 번들)** |


DMM/Android는 hook 엔진을 패키지에 정적 링크하지만, **iOS dylib은 hook 엔진이 외부에 있을 것으로 가정**합니다 (LiveContainer가 제공). Mac Catalyst엔 그런 시스템이 없어서 이 저장소가 **Dobby를 별도 dylib으로 직접 빌드해서 번들**합니다. 나머지(번역 데이터 자동 다운로드, IL2CPP hook 로직)는 기존 플랫폼과 완전히 동일합니다.

## 의존성


| 라이브러리                                                       | 버전        | 라이선스        | 역할                           |
| ----------------------------------------------------------- | --------- | ----------- | ---------------------------- |
| [jmpews/Dobby](https://github.com/jmpews/Dobby)             | `5dfc854` | Apache-2.0  | inline hook 엔진 (`DobbyHook`) |
| [Tyilo/insert_dylib](https://github.com/Tyilo/insert_dylib) | master    | MIT/BSD-ish | Mach-O에 `LC_LOAD_DYLIB` 추가   |


두 라이브러리 모두 저장소에는 **바이너리로 포함하지 않습니다**. `make setup`이 소스를 공식 GitHub에서 clone해서 빌드 → 결과물을 `tools/`로. `vendor/`와 빌드 산물은 `.gitignore`.

## 면책 / 법적

- 이 저장소는 **게임 바이너리, 번역 데이터, 외부 dylib을 재배포하지 않습니다**. 사용자가 이미 IPA로 설치한 로컬 번들에 한국어 번역 dylib(커뮤니티 배포본)을 주입하고 재서명하는 **자동화 도구만** 제공합니다.
- 한국어 dylib(`GakumasLocalifyIOS_KR.dylib`) 및 번역 데이터는 이곳에서 관리하지 않습니다. 저장소는 **사용자가 직접 획득**해야 합니다.
- 이 도구를 사용해 발생하는 모든 결과(계정 제재, 게임 오작동, 데이터 손실 등)에 대해 저장소 기여자는 일체 책임지지 않습니다.

