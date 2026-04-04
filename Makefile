MIN_XCODE_MAJOR ?= 26
REPO_ROOT := $(abspath .)
ZIG_SOURCE_DIR := vendor/zig
ZIG_LIB_DIR := $(abspath $(ZIG_SOURCE_DIR))/lib
ZIG_BUILD_DIR ?= .zig-toolchain/build
ZIG_INSTALL_DIR ?= .zig-toolchain/zig-0.15.2
ZIG_STAGE2 := $(abspath $(ZIG_BUILD_DIR))/zig2
ZIG := $(abspath $(ZIG_INSTALL_DIR))/bin/zig
HOT_GHOSTTY_BIN := $(abspath macos/build/Debug/Ghostty.app/Contents/MacOS/ghostty)
HOT_GHOSTTY_BIN_REL := macos/build/Debug/Ghostty.app/Contents/MacOS/ghostty
HOT_LOG := $(REPO_ROOT)/.hot-run.log
HOT_PID := $(REPO_ROOT)/.hot-run.pid
HOT_TAIL_CMD := tail -f $(HOT_LOG)
HOT_BUILD_RUN_CMD := $(ZIG) build run
HOT_BUILD_RUN_HOT_CMD := $(ZIG) build run -Dhot=true
GHOSTTY_RUN_ARGS := -- --config-default-files=false --window-vsync=false
HOT_INSTALL_CMD := cmake --build $(abspath $(ZIG_BUILD_DIR)) --target install
HOT_INSTALL_CMD_REL := cmake --build $(ZIG_BUILD_DIR) --target install
HOT_STAGE3_CMD := $(abspath $(ZIG_BUILD_DIR))/zig2 build --prefix $(abspath $(ZIG_INSTALL_DIR)) stage3
HOT_STAGE3_CHILD_CMD := $(abspath $(ZIG_BUILD_DIR))/zig2 lib $(abspath $(ZIG_SOURCE_DIR))
LLVM_PREFIX ?= $(shell brew --prefix llvm@20 2>/dev/null)
LLD_PREFIX ?= $(shell brew --prefix lld@20 2>/dev/null)
ZSTD_PREFIX ?= $(shell brew --prefix zstd 2>/dev/null)
LIBXML2_PREFIX ?= $(shell brew --prefix libxml2 2>/dev/null)
ZLIB_PREFIX ?= $(shell brew --prefix zlib 2>/dev/null)
ZIG_CMAKE_PREFIX_PATH := $(LLVM_PREFIX);$(LLD_PREFIX);$(ZSTD_PREFIX);$(LIBXML2_PREFIX);$(ZLIB_PREFIX)
ZIG_CMAKE_LIBRARY_PATH := $(LLD_PREFIX)/lib;$(LLVM_PREFIX)/lib;$(ZSTD_PREFIX)/lib;$(LIBXML2_PREFIX)/lib;$(ZLIB_PREFIX)/lib
ZIG_LDFLAGS := -L$(LLD_PREFIX)/lib -L$(ZSTD_PREFIX)/lib -L$(LIBXML2_PREFIX)/lib -L$(ZLIB_PREFIX)/lib
ZIG_CPPFLAGS := -I$(LLD_PREFIX)/include -I$(ZSTD_PREFIX)/include -I$(LIBXML2_PREFIX)/include -I$(ZLIB_PREFIX)/include
ZIG_DYLD_LIBRARY_PATH := $(LLVM_PREFIX)/lib:$(LLD_PREFIX)/lib:$(ZSTD_PREFIX)/lib:$(LIBXML2_PREFIX)/lib:$(ZLIB_PREFIX)/lib

init:
	@echo You probably want to run "zig build" instead.
.PHONY: init

check-zig-submodule:
	@if [ -f "$(ZIG_SOURCE_DIR)/CMakeLists.txt" ]; then \
		exit 0; \
	fi; \
	echo "error: $(ZIG_SOURCE_DIR) is missing. Run 'git submodule update --init --recursive $(ZIG_SOURCE_DIR)'." >&2; \
	exit 1
.PHONY: check-zig-submodule

check-xcode:
	@if [ "$$(uname -s)" != "Darwin" ] || [ "$${GHOSTTY_SKIP_XCODE_CHECK:-0}" = "1" ]; then \
		exit 0; \
	fi; \
	xcode_major=$$(xcodebuild -version 2>/dev/null | sed -n 's/^Xcode \([0-9][0-9]*\).*/\1/p' | head -n 1); \
	if [ -z "$$xcode_major" ]; then \
		echo "error: xcodebuild is unavailable. Install Xcode and select it with xcode-select." >&2; \
		exit 1; \
	fi; \
	if [ "$$xcode_major" -lt "$(MIN_XCODE_MAJOR)" ]; then \
		echo "error: Ghostty macOS builds on this branch require Xcode $(MIN_XCODE_MAJOR)+. Current version: $$xcode_major." >&2; \
		echo "hint: set GHOSTTY_SKIP_XCODE_CHECK=1 if you intentionally want to try anyway." >&2; \
		exit 1; \
	fi
.PHONY: check-xcode

check-llvm:
	@if [ -n "$(LLVM_PREFIX)" ] && [ -x "$(LLVM_PREFIX)/bin/llvm-config" ]; then \
		exit 0; \
	fi; \
	echo "error: llvm@20 was not found. Install it with Homebrew or set LLVM_PREFIX=/path/to/llvm@20." >&2; \
	exit 1
.PHONY: check-llvm

$(ZIG_STAGE2): check-zig-submodule check-llvm
	@mkdir -p "$(ZIG_BUILD_DIR)" "$(ZIG_INSTALL_DIR)"
	cd "$(ZIG_BUILD_DIR)" && \
		PATH="$(LLVM_PREFIX)/bin:$$PATH" \
		CPPFLAGS="$(ZIG_CPPFLAGS)" \
		LDFLAGS="$(ZIG_LDFLAGS)" \
		cmake "$(abspath $(ZIG_SOURCE_DIR))" \
			-G Ninja \
			-DCMAKE_BUILD_TYPE=Release \
			-DZIG_VERSION="0.15.2-dev.0+ghosttyhot" \
			-DCMAKE_PREFIX_PATH="$(ZIG_CMAKE_PREFIX_PATH)" \
			-DCMAKE_LIBRARY_PATH="$(ZIG_CMAKE_LIBRARY_PATH)" \
			-DCMAKE_INSTALL_PREFIX="$(abspath $(ZIG_INSTALL_DIR))"
	cmake --build "$(ZIG_BUILD_DIR)" --target zig2

$(ZIG): $(ZIG_STAGE2)
	cmake --build "$(ZIG_BUILD_DIR)" --target install

stock-run: $(ZIG)
	DYLD_LIBRARY_PATH="$(ZIG_DYLD_LIBRARY_PATH):$$DYLD_LIBRARY_PATH" \
		ZIG_LIB_DIR="$(ZIG_LIB_DIR)" "$(ZIG)" build run $(GHOSTTY_RUN_ARGS)
.PHONY: stock-run

hot-stop:
	@set -eu; \
	kill_pattern() { \
		pattern="$$1"; \
		pkill -TERM -f "$$pattern" 2>/dev/null || true; \
		for _ in 1 2 3 4 5; do \
			if ! pgrep -f "$$pattern" >/dev/null 2>&1; then \
				return 0; \
			fi; \
			sleep 1; \
		done; \
		pkill -KILL -f "$$pattern" 2>/dev/null || true; \
	}; \
	kill_pattern '$(HOT_GHOSTTY_BIN)'; \
	kill_pattern '$(HOT_GHOSTTY_BIN_REL)'; \
	kill_pattern '$(HOT_BUILD_RUN_CMD)'; \
	kill_pattern '$(HOT_BUILD_RUN_HOT_CMD)'; \
	kill_pattern '$(HOT_INSTALL_CMD)'; \
	kill_pattern '$(HOT_INSTALL_CMD_REL)'; \
	kill_pattern '$(HOT_STAGE3_CMD)'; \
	kill_pattern '$(HOT_STAGE3_CHILD_CMD)'; \
	kill_pattern '$(HOT_TAIL_CMD)'; \
	if [ -f "$(HOT_PID)" ]; then \
		pid=$$(cat "$(HOT_PID)" 2>/dev/null || true); \
		if [ -n "$$pid" ]; then \
			kill -TERM "$$pid" 2>/dev/null || true; \
			for _ in 1 2 3 4 5; do \
				if ! kill -0 "$$pid" >/dev/null 2>&1; then \
					break; \
				fi; \
				sleep 1; \
			done; \
			kill -KILL "$$pid" 2>/dev/null || true; \
		fi; \
	fi; \
	rm -f "$(REPO_ROOT)/.nrepl-port" "$(HOT_LOG)" "$(HOT_PID)"
.PHONY: hot-stop

hot-run: hot-stop
	$(MAKE) --no-print-directory "$(ZIG)"
	@mkdir -p "$(dir $(HOT_LOG))"
	@bash -lc 'set -euo pipefail; \
		rm -f "$(HOT_LOG)" "$(HOT_PID)"; \
		nohup env \
			DYLD_LIBRARY_PATH="$(ZIG_DYLD_LIBRARY_PATH):$${DYLD_LIBRARY_PATH:-}" \
			ZIG_LIB_DIR="$(ZIG_LIB_DIR)" \
			"$(ZIG)" build run -Dhot=true $(GHOSTTY_RUN_ARGS) >"$(HOT_LOG)" 2>&1 & \
		run_pid=$$!; \
		echo "$$run_pid" >"$(HOT_PID)"; \
		tail -f "$(HOT_LOG)" & \
		tail_pid=$$!; \
		wait "$$run_pid"; \
		status=$$?; \
		kill "$$tail_pid" 2>/dev/null || true; \
		wait "$$tail_pid" 2>/dev/null || true; \
		exit "$$status"'
.PHONY: hot-run

hot-compiler-test: $(ZIG)
	DYLD_LIBRARY_PATH="$(ZIG_DYLD_LIBRARY_PATH):$$DYLD_LIBRARY_PATH" ./hot-compiler-test.sh
.PHONY: hot-compiler-test

vendor-zig: $(ZIG)
.PHONY: vendor-zig

vendor-zig-install: $(ZIG)
.PHONY: vendor-zig-install

# glad updates the GLAD loader. To use this, place the generated glad.zip
# in this directory next to the Makefile, remove vendor/glad and run this target.
#
# Generator: https://gen.glad.sh/
glad: vendor/glad
.PHONY: glad

vendor/glad: vendor/glad/include/glad/gl.h vendor/glad/include/glad/glad.h

vendor/glad/include/glad/gl.h: glad.zip
	rm -rf vendor/glad
	mkdir -p vendor/glad
	unzip glad.zip -dvendor/glad
	find vendor/glad -type f -exec touch '{}' +

vendor/glad/include/glad/glad.h: vendor/glad/include/glad/gl.h
	@echo "#include <glad/gl.h>" > $@

clean:
	rm -rf \
		.zig-toolchain \
		zig-out .zig-cache \
		macos/build \
		macos/GhosttyKit.xcframework
.PHONY: clean
