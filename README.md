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

