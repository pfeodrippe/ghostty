MIN_XCODE_MAJOR ?= 26
REPO_ROOT := $(abspath .)
ZIG_SOURCE_DIR := vendor/zig
ZIG_LIB_DIR := $(abspath $(ZIG_SOURCE_DIR))/lib
ZIG_BUILD_DIR ?= .zig-toolchain/build
ZIG_INSTALL_DIR ?= .zig-toolchain/zig-0.15.2
ZIG_STAGE2 := $(abspath $(ZIG_BUILD_DIR))/zig2
ZIG := $(abspath $(ZIG_INSTALL_DIR))/bin/zig
ZIG_INSTALL_STAMP := $(abspath $(ZIG_INSTALL_DIR))/.install-stamp
ZIG_VERSION_STRING ?= 0.15.2-dev.0+ghosttyhot
HOT_LOG := $(REPO_ROOT)/.hot-run.log
HOT_PID := $(REPO_ROOT)/.hot-run.pid
TIGERBEETLE_DIR ?= $(abspath vendor/tigerbeetle)
GHOSTTY_RUN_ARGS := -- --config-default-files=false --window-vsync=false
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
ZIG_SELFHOST_BUILD_ARGS := \
	--zig-lib-dir "$(ZIG_LIB_DIR)" \
	"-Dversion-string=$(ZIG_VERSION_STRING)" \
	"-Dtarget=native" \
	"-Dcpu=native" \
	-Denable-llvm \
	"-Dconfig_h=$(abspath $(ZIG_BUILD_DIR))/config.h" \
	-Dno-langref \
	-Doptimize=ReleaseFast \
	-Dstrip

ifneq ($(wildcard $(ZIG_SOURCE_DIR)/CMakeLists.txt),)
# Make needs explicit edges from the vendored Zig submodule into both the
# staged compiler build and the installed toolchain contents. `zig2` itself
# won't rebuild for lib-only edits, but `cmake --build --target install` still
# needs to run when the final CLI/runtime changes. Build-script-only std changes
# (such as std.Build.Hot) are consumed directly from ZIG_LIB_DIR during `zig build`
# and should not force a stage3 reinstall.
ZIG_BUILD_PREREQS := $(addprefix $(ZIG_SOURCE_DIR)/,$(shell cd "$(ZIG_SOURCE_DIR)" && git ls-files CMakeLists.txt cmake src stage1 stage2))
ZIG_INSTALL_PREREQS := $(filter-out \
	$(ZIG_SOURCE_DIR)/lib/std/Build.zig \
	$(ZIG_SOURCE_DIR)/lib/std/Build/% \
	$(ZIG_SOURCE_DIR)/lib/std/build_runner.zig, \
	$(addprefix $(ZIG_SOURCE_DIR)/,$(shell cd "$(ZIG_SOURCE_DIR)" && git ls-files build.zig CMakeLists.txt cmake lib src stage1 stage2)))
endif

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

$(ZIG_STAGE2): $(ZIG_BUILD_PREREQS) | check-zig-submodule check-llvm
	@mkdir -p "$(ZIG_BUILD_DIR)" "$(ZIG_INSTALL_DIR)"
	cd "$(ZIG_BUILD_DIR)" && \
		PATH="$(LLVM_PREFIX)/bin:$$PATH" \
		CPPFLAGS="$(ZIG_CPPFLAGS)" \
		LDFLAGS="$(ZIG_LDFLAGS)" \
		cmake "$(abspath $(ZIG_SOURCE_DIR))" \
			-G Ninja \
			-DCMAKE_BUILD_TYPE=Release \
			-DZIG_VERSION="$(ZIG_VERSION_STRING)" \
			-DCMAKE_PREFIX_PATH="$(ZIG_CMAKE_PREFIX_PATH)" \
			-DCMAKE_LIBRARY_PATH="$(ZIG_CMAKE_LIBRARY_PATH)" \
			-DCMAKE_INSTALL_PREFIX="$(abspath $(ZIG_INSTALL_DIR))"
	cmake --build "$(ZIG_BUILD_DIR)" --target zig2

$(ZIG_INSTALL_STAMP): $(ZIG_STAGE2) $(ZIG_INSTALL_PREREQS)
	@set -euo pipefail; \
		needs_bootstrap=0; \
		bootstrap_dirs="$(ZIG_SOURCE_DIR)/cmake $(ZIG_SOURCE_DIR)/stage1"; \
		if [ -d "$(ZIG_SOURCE_DIR)/stage2" ]; then \
			bootstrap_dirs="$$bootstrap_dirs $(ZIG_SOURCE_DIR)/stage2"; \
		fi; \
		if [ ! -x "$(ZIG)" ] || [ ! -f "$@" ] || [ "$(ZIG_STAGE2)" -nt "$@" ]; then \
			needs_bootstrap=1; \
		fi; \
		if [ "$$needs_bootstrap" -eq 0 ] && [ "$(ZIG_SOURCE_DIR)/CMakeLists.txt" -nt "$@" ]; then \
			needs_bootstrap=1; \
		fi; \
		if [ "$$needs_bootstrap" -eq 0 ] && \
			find $$bootstrap_dirs -type f -newer "$@" -print -quit | grep -q .; then \
			needs_bootstrap=1; \
		fi; \
		if [ "$$needs_bootstrap" -eq 1 ]; then \
			echo "Installing patched Zig stage3 toolchain into $(ZIG_INSTALL_DIR) via zig2 bootstrap (this can take several minutes after bootstrap changes)..."; \
			cmake --build "$(ZIG_BUILD_DIR)" --target install; \
		else \
			echo "Installing patched Zig stage4 toolchain into $(ZIG_INSTALL_DIR) via self-hosted zig..."; \
			cd "$(ZIG_SOURCE_DIR)" && \
				PATH="$(LLVM_PREFIX)/bin:$$PATH" \
				DYLD_LIBRARY_PATH="$(ZIG_DYLD_LIBRARY_PATH):$${DYLD_LIBRARY_PATH:-}" \
				"$(ZIG)" build --prefix "$(abspath $(ZIG_INSTALL_DIR))" $(ZIG_SELFHOST_BUILD_ARGS); \
		fi; \
		touch "$@"

vendor-zig-install: $(ZIG_INSTALL_STAMP)
.PHONY: vendor-zig-install

stock-run: $(ZIG_INSTALL_STAMP)
	DYLD_LIBRARY_PATH="$(ZIG_DYLD_LIBRARY_PATH):$$DYLD_LIBRARY_PATH" \
		ZIG_LIB_DIR="$(ZIG_LIB_DIR)" "$(ZIG)" build run $(GHOSTTY_RUN_ARGS)
.PHONY: stock-run

hot-stop:
	@set -eu; \
		collect_descendants() { \
		current="$$1"; \
		children=$$(pgrep -P "$$current" 2>/dev/null || true); \
		if [ -z "$$children" ]; then \
			return 0; \
		fi; \
		for child in $$children; do \
			collect_descendants "$$child"; \
			printf "%s\n" "$$child"; \
		done; \
	}; \
		stop_pids() { \
		pids="$$1"; \
		if [ -z "$$pids" ]; then \
			return 0; \
		fi; \
		for target in $$pids; do \
			if [ -n "$$target" ]; then \
				kill -TERM "$$target" 2>/dev/null || true; \
			fi; \
		done; \
		for _ in 1 2 3 4 5; do \
			alive=0; \
			for target in $$pids; do \
				if [ -n "$$target" ] && kill -0 "$$target" >/dev/null 2>&1; then \
					alive=1; \
					break; \
				fi; \
			done; \
			if [ "$$alive" -eq 0 ]; then \
				return 0; \
			fi; \
			sleep 1; \
		done; \
		for target in $$pids; do \
			if [ -n "$$target" ]; then \
				kill -KILL "$$target" 2>/dev/null || true; \
			fi; \
		done; \
	}; \
		stop_pid_file() { \
		pid_file="$$1"; \
		if [ ! -f "$$pid_file" ]; then \
			return 0; \
		fi; \
		pid=$$(cat "$$pid_file" 2>/dev/null || true); \
		if [ -z "$$pid" ]; then \
			return 0; \
		fi; \
		pids="$$(collect_descendants "$$pid" || true)"; \
		pids="$$pids $$pid"; \
		stop_pids "$$pids"; \
	}; \
		stop_stale_hot_processes() { \
		hot_cmd_abs="$(REPO_ROOT)/macos/build/Debug/Ghostty.app/Contents/MacOS/ghostty --config-default-files=false --window-vsync=false"; \
		hot_cmd_rel="macos/build/Debug/Ghostty.app/Contents/MacOS/ghostty --config-default-files=false --window-vsync=false"; \
		self_pid=$$$$; \
		parent_pid=$$PPID; \
		matched=$$(ps -o pid= -o command= -ax | awk -v hot_cmd_abs="$$hot_cmd_abs" -v hot_cmd_rel="$$hot_cmd_rel" -v self_pid="$$self_pid" -v parent_pid="$$parent_pid" "(index(\$$0, hot_cmd_abs) || index(\$$0, hot_cmd_rel)) && \$$1 != self_pid && \$$1 != parent_pid { print \$$1 }" | sort -u); \
		if [ -z "$$matched" ]; then \
			return 0; \
		fi; \
		pids=""; \
		for target in $$matched; do \
			pids="$$pids $$(collect_descendants "$$target" || true) $$target"; \
		done; \
		stop_pids "$$pids"; \
	}; \
	stop_pid_file "$(HOT_PID)"; \
	stop_stale_hot_processes; \
	rm -f "$(REPO_ROOT)/.nrepl-port" "$(HOT_LOG)" "$(HOT_PID)"
.PHONY: hot-stop

hot-run: hot-stop $(ZIG_INSTALL_STAMP)
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

hot-test: hot-stop $(ZIG_INSTALL_STAMP)
	@mkdir -p "$(dir $(HOT_LOG))"
	@bash -lc 'set -euo pipefail; \
		rm -f "$(HOT_LOG)" "$(HOT_PID)"; \
		cleanup() { "$(MAKE)" hot-stop >/dev/null 2>&1 || true; }; \
		trap cleanup EXIT INT TERM; \
		nohup env \
			DYLD_LIBRARY_PATH="$(ZIG_DYLD_LIBRARY_PATH):$${DYLD_LIBRARY_PATH:-}" \
			ZIG_LIB_DIR="$(ZIG_LIB_DIR)" \
			"$(ZIG)" build run -Dhot=true $(GHOSTTY_RUN_ARGS) >"$(HOT_LOG)" 2>&1 & \
		run_pid=$$!; \
		echo "$$run_pid" >"$(HOT_PID)"; \
		./hot-smoke-test.sh'
.PHONY: hot-test

hot-compiler-test: $(ZIG_INSTALL_STAMP)
	DYLD_LIBRARY_PATH="$(ZIG_DYLD_LIBRARY_PATH):$$DYLD_LIBRARY_PATH" ./hot-compiler-test.sh
.PHONY: hot-compiler-test

test-hot-all:
	@bash -lc 'set -euo pipefail; \
		log="/tmp/ghostty-test-hot-all.log"; \
		rm -f "$$log"; \
		exec > >(tee "$$log") 2>&1; \
		echo "log\t$$log"; \
		rm -rf .zig-cache; \
		"$(MAKE)" hot-compiler-test; \
		"$(MAKE)" hot-test; \
		"$(MAKE)" -C "$(TIGERBEETLE_DIR)" HOT_ZIG="$(ZIG)" HOT_ZIG_LIB_DIR="$(ZIG_LIB_DIR)" hot-test; \
		rm -rf .zig-cache'
.PHONY: test-hot-all

vendor-zig: vendor-zig-install
.PHONY: vendor-zig

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
