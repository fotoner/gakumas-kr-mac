# gakumas-kr-mac

> Mac에서 학원 아이돌마스터(学園アイドルマスター) 한국어 패치를 자동 적용하는 도구

[PlayCover](https://playcover.io)로 설치한 학원마스를 한국어로 플레이하게 해줍니다. Mac 환경에 맞게 플랫폼 변환 + 주입 + 재서명까지 수행.

## 요구사항

- Apple Silicon Mac, macOS 14+ (Sonoma 이상, **macOS 26 Tahoe·macOS 27 검증 완료**)
- [PlayCover](https://playcover.io) 3.0+로 임포트한 학원마스 — `make run`이 PlayCover 설정과 로그인 저장소를 점검하므로 다른 IPA 런타임은 지원하지 않습니다
  - 앱은 `/Applications`, `~/Applications`, PlayCover 컨테이너에서 자동으로 찾습니다. 없거나 여러 개면 `make patch APP=<.app 경로>`처럼 지정
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

실행은 항상 `make run`으로 하세요. PlayCover의 Play 버튼은 앱을 다시 서명하고, KeyCover를 켠 경우 로그인 저장소를 예전 상태로 되돌리거나 잠글 수 있습니다.

`make run`은 실행 직전 로그인 저장소(PlayChain)를 점검해, 통과하면 백업한 뒤 같은 계정의 중복 행을 최신 하나로 정리합니다. 문제가 있으면 해결 방법을 출력하고 멈춥니다. PlayCover를 종료한 상태에서 실행하고, 처음 실행이라 로그인 정보가 아직 없으면 `GAKU_ALLOW_EMPTY_CHAIN=1 make run`으로 실행하세요.

Xcode 라이선스에 동의하지 않아 `make`가 exit 69로 실패하면 `DEVELOPER_DIR=/Library/Developer/CommandLineTools make run`처럼 앞에 붙여 실행합니다.

### 기타 명령

```bash
make verify            # 현재 패치 상태 확인
make playchain-status  # 로그인 저장소(PlayChain) 상태 확인, 읽기 전용
make logs              # 실행 중 번역 dylib 로그 스트리밍
make revert            # 패치 되돌리기 (원본 복원)
make clean             # 빌드 산물 삭제 (vendor/는 유지)
make help              # 도움말
```

## 재실행하면 로그인이 풀릴 때

PlayCover는 키체인 대신 자체 SQLite 저장소(PlayChain)를 쓰는데, 학원마스의 로그인 정보는 저장할 때마다 덮어쓰이지 않고 새 행으로 쌓이고 읽을 때는 가장 오래된 행이 돌아옵니다. 그래서 재실행하면 예전 계정(게스트 등)으로 돌아갈 수 있습니다. PlayCover KeyCover가 오래된 저장소 스냅샷을 복원해도 같은 증상이 납니다.

`tools/login-persistence-poc/`의 선택적 수정은 학원마스 프로세스 안에서만 PlayChain이 같은 항목을 실제 키체인처럼 한 행으로 유지하게 합니다. 기본 `make patch`에는 포함되지 않습니다. Xcode 또는 Command Line Tools의 macOS SDK, Python 3, Git이 필요하고, `make setup`·`make patch`를 마친 뒤 저장소 루트에서 실행합니다.

```bash
# 테스트용 PlayTools 소스 (고정 커밋, Git 추적 제외)
git clone --filter=blob:none --no-checkout https://github.com/PlayCover/PlayTools.git \
  tools/login-persistence-poc/PlayTools-source
git -C tools/login-persistence-poc/PlayTools-source checkout --detach \
  f2bfbd76ff55f4737c959fa2eac07f9ada2e6d7e

python3 tools/login-persistence-poc/build-and-test.py  # 가짜 DB로 테스트 + dylib 빌드
bash tools/login-persistence-poc/apply.sh              # 게임을 종료한 상태에서 적용
make run
make playchain-status                                  # 로그인 저장소 확인 (읽기 전용)
bash tools/login-persistence-poc/rollback.sh           # 제거 (한국어 패치·로그인 정보 유지)
```

- 학원마스 3.4.0(build 89) 전용입니다. 다른 버전에는 `apply.sh`가 적용을 거부합니다.
- IPA를 다시 임포트하면 수정이 사라집니다. `make patch` 후 다시 적용하세요.
- PlayCover 업데이트로 PlayTools가 검증한 빌드와 달라지면 `make run`이 경고합니다. 그 뒤 로그인이 다시 풀리면 `rollback.sh`로 수정을 제거하고 이슈로 알려주세요.

테스트용 PlayTools 소스([PlayChain 구현](https://github.com/PlayCover/PlayTools/tree/f2bfbd76ff55f4737c959fa2eac07f9ada2e6d7e/PlayTools/MysticRunes), AGPL-3.0)는 로컬에만 받으며 저장소에 포함하지 않습니다.

## 작동 원리

**기본 원리는 DMM(Windows) / Android 한글패치와 동일합니다.** 학원마스 프로세스에 `GakumasLocalify` dylib을 로드시키고, Unity IL2CPP 함수(TextMeshPro 등 텍스트 출력 루틴)를 **inline hook**으로 가로채서 일본어 → 한국어로 치환하는 방식. 번역 데이터(`localization.json`, `generic.json` 등)는 dylib이 GitHub 릴리스에서 자동 다운로드합니다.

### 플랫폼별 차이

| 플랫폼             | 주입 방식                                     | Hook 엔진                            |
| --------------- | ----------------------------------------- | ---------------------------------- |
| Windows (DMM)   | `version.dll` DLL 하이재킹                    | MinHook (dll에 정적 링크)               |
| Android         | LSPatch로 APK 병합 (`libMarryKotone.so`)     | ShadowHook + xdl (`.so` 번들)        |
| iOS             | LiveContainer / Cydia Substrate가 dylib 로드 | 시스템 tweak 인프라가 제공                  |
| **Mac (이 저장소)** | Mach-O `LC_LOAD_DYLIB` 추가 + adhoc 재서명     | **Dobby (`libdobby.dylib` 별도 번들)** |

DMM/Android는 hook 엔진을 패키지에 정적 링크하지만, **iOS dylib은 hook 엔진이 외부에 있을 것으로 가정**합니다 (LiveContainer가 제공). Mac Catalyst엔 그런 시스템이 없어서 이 저장소가 **Dobby를 별도 dylib으로 직접 빌드해서 번들**합니다. 나머지(번역 데이터 자동 다운로드, IL2CPP hook 로직)는 기존 플랫폼과 동일합니다.

## 의존성

| 라이브러리                                                       | 버전        | 라이선스        | 역할                           |
| ----------------------------------------------------------- | --------- | ----------- | ---------------------------- |
| [jmpews/Dobby](https://github.com/jmpews/Dobby)             | `5dfc854` | Apache-2.0  | inline hook 엔진 (`DobbyHook`) |
| [Tyilo/insert_dylib](https://github.com/Tyilo/insert_dylib) | master    | MIT/BSD-ish | Mach-O에 `LC_LOAD_DYLIB` 추가   |

두 라이브러리 모두 저장소에 **바이너리로 포함하지 않습니다**. `make setup`이 공식 GitHub에서 소스를 clone해 빌드하고 결과물을 `tools/`에 둡니다. `vendor/`와 빌드 산물은 `.gitignore`.

## 면책 / 법적

- 이 저장소는 **게임 바이너리, 번역 데이터, 외부 dylib을 재배포하지 않습니다**. 사용자가 이미 IPA로 설치한 로컬 번들에 한국어 번역 dylib(커뮤니티 배포본)을 주입하고 재서명하는 **자동화 도구만** 제공합니다.
- 한국어 dylib(`GakumasLocalifyIOS_KR.dylib`) 및 번역 데이터는 이곳에서 관리하지 않으며 **사용자가 직접 획득**해야 합니다.
- 이 도구를 사용해 발생하는 모든 결과(계정 제재, 게임 오작동, 데이터 손실 등)에 대해 저장소 기여자는 일체 책임지지 않습니다.
