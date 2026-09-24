# gakumas-kr-mac — 학원마스 한국어 패치 (Mac IPA 런타임)
#
# 지원: IPA로 설치된 학원마스 (검증: PlayCover). 앱 위치는 자동 탐색, 다른 곳이면 APP=<.app 경로>
#
# 사용:
#   make           - help 표시
#   make setup     - 의존성 clone + 빌드 (최초 1회 또는 재빌드)
#   make patch     - 학원마스 번들 패치
#   make run       - 재서명 + 실행 (IPA 런타임 UI 우회)
#   make revert    - 패치 되돌리기
#   make logs      - 실행 중 dylib 로그 스트리밍
#   make verify    - 현재 패치 상태 검증
#   make playchain-status - 로그인 DB(PlayChain) 상태 확인 (읽기 전용)
#   make clean     - 빌드 산물만 삭제
#   make clean-all - vendor/ 포함 전부 삭제

ROOT   := $(shell pwd)
TOOLS  := $(ROOT)/tools
VENDOR := $(ROOT)/vendor

# APP 미지정 시 자동 탐색 (tools/lib/common.sh find_app). 못 찾으면 빈 값 → 각 스크립트가 이유와 함께 실패
ifeq ($(strip $(APP)),)
APP := $(shell bash -c '. "$(TOOLS)/lib/common.sh" && find_app' 2>/dev/null)
endif
BIN := $(APP)/idolmaster_gakuen

# --- 의존성 버전 pin (재현성 확보) -----------------------------------------
# Dobby: 2026-04-22 master HEAD (Day 0 스파이크에서 검증된 커밋)
DOBBY_REPO := https://github.com/jmpews/Dobby
DOBBY_REF  := 5dfc854

# insert_dylib (Tyilo 포크): 안정적, master HEAD 허용
INSERT_DYLIB_REPO := https://github.com/Tyilo/insert_dylib
INSERT_DYLIB_REF  := master

# --- 타겟 ------------------------------------------------------------------

.PHONY: help setup patch run revert logs verify playchain-status clean clean-all

help:
	@echo "gakumas-kr-mac 사용법:"
	@echo ""
	@echo "  make setup    - 의존성 clone + 빌드 (libdobby.dylib, insert_dylib)"
	@echo "  make patch    - 학원마스 번들에 dylib 주입 + 재서명"
	@echo "  make run      - 재서명 후 게임 실행 (런타임 UI 우회)"
	@echo "  make revert   - 패치 되돌리기 (원본 복원)"
	@echo "  make logs     - 실행 중 dylib 로그 스트리밍"
	@echo "  make verify   - 현재 패치 상태 검증"
	@echo "  make playchain-status - 로그인 DB(PlayChain) 상태 확인 (읽기 전용)"
	@echo "  make clean    - 빌드 산물 삭제 (vendor/는 유지)"
	@echo "  make clean-all - vendor/ 포함 전부 삭제"
	@echo ""
	@echo "앱: $(if $(APP),$(APP),(찾지 못함 — APP=<.app 경로> 로 지정))"
	@echo ""
	@echo "Xcode 라이선스 미동의로 make 가 exit 69 로 실패하면:"
	@echo "  DEVELOPER_DIR=/Library/Developer/CommandLineTools make run"
	@echo ""
	@echo "의존성:"
	@echo "  Dobby $(DOBBY_REF)"
	@echo "  insert_dylib $(INSERT_DYLIB_REF)"

# === setup: 빌드 산물 2개가 있으면 완료 ===================================
setup: $(TOOLS)/libdobby.dylib $(TOOLS)/insert_dylib
	@echo "✓ setup 완료"

# --- Dobby 빌드 -----------------------------------------------------------
# CMake 일부 서브타겟이 간헐적으로 실패해도 libdobby.dylib 자체는 생성됨.
# 따라서 빌드 exit code 무시하고 결과물 존재로 성공 판단.
$(TOOLS)/libdobby.dylib: $(VENDOR)/Dobby/.cloned
	@command -v cmake >/dev/null || (echo "ERROR: cmake 필요 — 'brew install cmake'"; exit 1)
	@echo "→ Dobby 빌드 (arm64 shared lib)"
	@cd $(VENDOR)/Dobby && rm -rf build && mkdir build && cd build && \
		cmake .. \
			-DCMAKE_OSX_ARCHITECTURES=arm64 \
			-DBUILD_SHARED_LIBS=ON \
			-DCMAKE_BUILD_TYPE=Release \
			-DDOBBY_DEBUG=OFF \
			-DDOBBY_BUILD_EXAMPLE=OFF \
			-DDOBBY_BUILD_TEST=OFF > /dev/null 2>&1
	@cd $(VENDOR)/Dobby/build && \
		cmake --build . --parallel $$(sysctl -n hw.ncpu) > /dev/null 2>&1 || true
	@test -f $(VENDOR)/Dobby/build/libdobby.dylib || \
		{ echo "ERROR: libdobby.dylib 빌드 실패"; exit 1; }
	@echo "→ 플랫폼 변환 (macOS → macCatalyst)"
	@vtool -set-build-version maccatalyst 11.0 14.0 -replace \
		-output $@.tmp $(VENDOR)/Dobby/build/libdobby.dylib > /dev/null 2>&1
	@mv $@.tmp $@
	@chmod +x $@
	@echo "   $(TOOLS)/libdobby.dylib ($$(/usr/bin/stat -f '%z' $@) bytes, $$(vtool -show-build $@ | awk '/platform/ {print $$2}'))"

$(VENDOR)/Dobby/.cloned:
	@mkdir -p $(VENDOR)
	@if [ ! -d $(VENDOR)/Dobby ]; then \
		echo "→ Dobby clone ($(DOBBY_REPO) @ $(DOBBY_REF))"; \
		git clone $(DOBBY_REPO) $(VENDOR)/Dobby; \
		cd $(VENDOR)/Dobby && git checkout $(DOBBY_REF); \
	fi
	@touch $@

# --- insert_dylib 빌드 ----------------------------------------------------
$(TOOLS)/insert_dylib: $(VENDOR)/insert_dylib/.cloned
	@echo "→ insert_dylib 빌드"
	@clang -O2 -o $@ $(VENDOR)/insert_dylib/insert_dylib/main.c
	@chmod +x $@
	@echo "   $(TOOLS)/insert_dylib ($$(/usr/bin/stat -f '%z' $@) bytes)"

$(VENDOR)/insert_dylib/.cloned:
	@mkdir -p $(VENDOR)
	@if [ ! -d $(VENDOR)/insert_dylib ]; then \
		echo "→ insert_dylib clone ($(INSERT_DYLIB_REPO) @ $(INSERT_DYLIB_REF))"; \
		git clone $(INSERT_DYLIB_REPO) $(VENDOR)/insert_dylib; \
		cd $(VENDOR)/insert_dylib && git checkout $(INSERT_DYLIB_REF); \
	fi
	@touch $@

# === 워크플로우 ============================================================

patch: setup
	@APP="$(APP)" bash $(TOOLS)/patch.sh

run:
	@APP="$(APP)" bash $(TOOLS)/resign-with-jit.sh

revert:
	@APP="$(APP)" bash $(TOOLS)/revert.sh

logs:
	@bash $(TOOLS)/watch-logs.sh

verify:
	@APP="$(APP)" bash -c '. "$(TOOLS)/lib/common.sh" && find_app' >/dev/null
	@echo "=== 서명 검증 ==="
	@codesign --verify --verbose "$(APP)" 2>&1 | head -2 | sed 's/^/  /'
	@echo ""
	@echo "=== 주입된 dylib (로드 커맨드 수 — 정상: 각 1) ==="
	@for n in GakumasLocalifyIOS_KR libdobby GakuPlayChainCompat PlayTools; do \
		c=$$(python3 "$(TOOLS)/macho-loads.py" "$(BIN)" --count $$n) || exit 1; \
		echo "  $$n: $$c"; \
	done
	@echo ""
	@echo "=== JIT 엔타이틀먼트 ==="
	@if codesign -d --entitlements - "$(BIN)" 2>&1 | grep -q allow-jit; then echo "  allow-jit 있음"; \
		else echo "  (없음 — make run 이 실행 직전에 추가)"; fi

playchain-status:
	@python3 "$(TOOLS)/login-persistence-poc/playchain-recover.py" check

# === 정리 ==================================================================

clean:
	@rm -f $(TOOLS)/libdobby.dylib $(TOOLS)/insert_dylib
	@echo "✓ 빌드 산물 삭제 (vendor/는 유지 — 재빌드 시 clone 건너뜀)"

clean-all: clean
	@rm -rf $(VENDOR)
	@echo "✓ vendor/ 삭제"
