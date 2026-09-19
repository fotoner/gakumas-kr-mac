# gakumas-kr-mac

> Mac에서 학원 아이돌마스터(学園アイドルマスター) 한국어 패치를 자동 적용하는 도구

PlayCover 등 **IPA로 iOS 앱을 실행하는 Mac 런타임**에서 학원마스를 한국어로 플레이하게 해줍니다. Mac 환경에 맞게 플랫폼 변환 + 주입 + 재서명까지 수행.

## 요구사항

- Apple Silicon Mac, macOS 14+ (Sonoma 이상, **macOS 26 Tahoe 검증 완료**)
- IPA로 학원마스가 설치된 Mac 런타임
  - **검증 환경**: [PlayCover](https://playcover.io) 3.0+
  - 다른 IPA 런타임 (LiveContainer 등)도 원리적으로 가능 — `tools/patch.sh`의 `APP` 변수만 해당 번들 경로로 지정
- `[cmake](https://cmake.org/)` (없으면 `brew install cmake`)
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

### 기타 명령

```bash
make verify   # 현재 패치 상태 확인
make logs     # 실행 중 번역 dylib 로그 스트리밍
make revert   # 패치 되돌리기 (원본 복원)
make clean    # 빌드 산물 삭제 (vendor/는 유지)
make help     # 도움말
```

### 재실행 시 로그인이 풀리는 경우: 선택적 PoC

학원마스 3.4.0(build 89) + PlayCover 3.1.0 + PlayTools 1.1.7에서 Firebase의 저장 로그인 조회가 실패하는 문제를 확인했습니다. Firebase는 숫자 `kSecMatchLimit=2`로 배열을 요청하지만 PlayChain이 단일 dictionary를 반환해 `ERROR_KEYCHAIN_ERROR`가 발생합니다. [Firebase 조회 코드](https://github.com/firebase/firebase-ios-sdk/blob/85560b48b0ff099ad83fe53d67df3c67fbc2b7a6/FirebaseAuth/Sources/Swift/Storage/AuthKeychainServices.swift#L140), [PlayTools 반환 코드](https://github.com/PlayCover/PlayTools/blob/f2bfbd76ff55f4737c959fa2eac07f9ada2e6d7e/PlayTools/MysticRunes/PlayedApple.swift#L114)

[학원마스 전용 보정 코드](tools/login-persistence-poc/src/PlayChainCompat.m)는 해당 조회를 배열로 반환하도록 보정합니다. 로그인 저장소에 쓰거나 공용 PlayTools를 교체하지 않습니다. 적용 후 실제 게임에서 로그인 복원 오류 소멸과 종료·재실행 후 기존 계정 홈 진입을 확인했습니다. 기본 `make patch`에는 포함되지 않은 **선택적 PoC**입니다.

Apple Silicon Mac, Xcode의 macOS SDK, Python 3, Git이 필요합니다. 먼저 위의 `make setup`과 `make patch`를 완료하세요. 아래 명령은 저장소 루트에서 실행합니다.

```bash
# 테스트용 공식 PlayTools 소스 — 고정 커밋, Git 추적 제외
git clone --filter=blob:none --no-checkout https://github.com/PlayCover/PlayTools.git \
  tools/login-persistence-poc/PlayTools-source
git -C tools/login-persistence-poc/PlayTools-source checkout --detach \
  f2bfbd76ff55f4737c959fa2eac07f9ada2e6d7e

# 별도 임시 DB의 가짜 로그인 데이터로 테스트하고 PoC dylib 빌드
python3 tools/login-persistence-poc/build-and-test.py

# 게임을 종료한 상태에서 적용 후 실행
bash tools/login-persistence-poc/apply.sh
make run

# 게임을 종료한 상태에서 PoC만 제거 — 한국어 패치와 로그인 DB 유지
bash tools/login-persistence-poc/rollback.sh
make run
```

테스트는 [실제 PlayChain 소스와 재현 코드](tools/login-persistence-poc/src/main.swift)를 컴파일해 6개 프로세스에서 저장, 기존 오류 재현, 재실행, 세션 갱신 후 재실행을 검증합니다. 숫자 제한, 항목별 데이터, 없는 항목, 단일 조회, attributes-only 조회를 포함한 **46개 검증을 통과**했습니다. 실행 기록은 로컬 `test-results.txt`에 생성되며 공개하지 않습니다.

PoC의 한계와 복구 범위:

- 숫자 제한이 1보다 큰 generic password의 attributes+data 조회만 보정합니다. 다른 조회는 기존 구현에 전달합니다.
- 같은 primary key를 가진 중복 행은 기존 one 조회로 구분할 수 없습니다. 첫 항목 선택을 유지하며, 기존 중복 항목을 삭제하거나 중복 경고를 없애지는 않습니다.
- 암호화된 KeyCover와 평문 PlayChain DB가 함께 존재할 때의 동기화 문제까지 해결하지 않습니다. 실행은 계속 `make run`을 사용하세요.
- 적용·복구 스크립트는 3.4.0(build 89)에 한정합니다. 다른 버전은 추가 검증이 필요합니다. 재임포트하면 PoC는 사라지므로 이전 설치의 백업을 새 설치에 복원하지 마세요.
- 적용 직전 실행 파일과 엔타이틀먼트는 로컬 `private-backup/`에 보관하고, 기존 `.orig`는 보존합니다. 다른 경로에서 이미 적용한 PoC는 그 경로의 복구 스크립트를 사용하세요.
- PoC 진단은 반환 형식·항목 수·사용자 객체 존재 여부만 기록합니다. 토큰과 사용자 식별자를 출력하지 않습니다. Firebase 자체의 중복 경고 등 원래 게임 로그에는 민감한 값이 포함될 수 있으므로 로그 전체를 공개하지 마세요.

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

