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
HOT_PORT_FILE := $(REPO_ROOT)/.nrepl-port
HOT_BUILD_CACHE_DIR ?= $(REPO_ROOT)/.zig-hot-build-cache
HOT_GLOBAL_CACHE_DIR ?= $(REPO_ROOT)/.zig-hot-global-cache
HOT_THUNK_CACHE_DIR ?= $(REPO_ROOT)/.zig-hot-thunks
HOT_BUILD_CACHE_MAX_GIB ?= 24
HOT_THUNK_CACHE_MAX_GIB ?= 6
HOT_ZIG_CACHE_ARGS := --cache-dir "$(HOT_BUILD_CACHE_DIR)" --global-cache-dir "$(HOT_GLOBAL_CACHE_DIR)"
HOT_CONFIG_FILE := $(HOT_BUILD_CACHE_DIR)/hot/ghostty.config
HOT_TEST_CLEAN ?= 0
HOT_TEST_PROMOTION_WORKERS ?= 2
HOT_TEST_PROMOTION_DELAY_MS ?= 300
TIGERBEETLE_DIR ?= $(abspath vendor/tigerbeetle)
CODE_BIN ?= code
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
# (such as std.Build.Hot and lib/compiler/hot) are consumed directly from
# ZIG_LIB_DIR during `zig build` and should not force a staged reinstall.
ZIG_BUILD_PREREQS := $(addprefix $(ZIG_SOURCE_DIR)/,$(shell cd "$(ZIG_SOURCE_DIR)" && git ls-files CMakeLists.txt cmake src stage1 stage2))
ZIG_INSTALL_PREREQS := $(filter-out \
	$(ZIG_SOURCE_DIR)/lib/hot_test_suite.zig \
	$(ZIG_SOURCE_DIR)/lib/std/Build.zig \
	$(ZIG_SOURCE_DIR)/lib/std/Build/% \
	$(ZIG_SOURCE_DIR)/lib/compiler/hot/% \
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
	rm -f "$(HOT_PORT_FILE)" "$(HOT_LOG)" "$(HOT_PID)" "$(HOT_CONFIG_FILE)"
.PHONY: hot-stop

hot-run: hot-stop $(ZIG_INSTALL_STAMP)
	@mkdir -p "$(dir $(HOT_LOG))"
	@bash -lc 'set -euo pipefail; \
		./tools/prune-hot-cache.sh "$(HOT_THUNK_CACHE_DIR)" "$(HOT_THUNK_CACHE_MAX_GIB)" "ghostty hot thunk cache"; \
		mkdir -p "$(HOT_BUILD_CACHE_DIR)" "$(HOT_GLOBAL_CACHE_DIR)"; \
		rm -f "$(HOT_LOG)" "$(HOT_PID)" "$(HOT_PORT_FILE)" "$(HOT_CONFIG_FILE)"; \
		nohup env \
			DYLD_LIBRARY_PATH="$(ZIG_DYLD_LIBRARY_PATH):$${DYLD_LIBRARY_PATH:-}" \
			ZIG_LIB_DIR="$(ZIG_LIB_DIR)" \
			ZIG_HOT_CACHE_DIR="$(HOT_THUNK_CACHE_DIR)" \
			"$(ZIG)" build $(HOT_ZIG_CACHE_ARGS) run -Dhot=true $(GHOSTTY_RUN_ARGS) >"$(HOT_LOG)" 2>&1 & \
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
		clean_dir() { \
			local path="$$1"; \
			if [ -e "$$path" ]; then \
				echo "clean\t$$path"; \
				rm -rf "$$path"; \
			fi; \
		}; \
		if [ "$(HOT_TEST_CLEAN)" = "1" ]; then \
			clean_dir "$(HOT_BUILD_CACHE_DIR)"; \
			clean_dir "$(HOT_GLOBAL_CACHE_DIR)"; \
			clean_dir "$(HOT_THUNK_CACHE_DIR)"; \
		else \
			./tools/prune-hot-cache.sh "$(HOT_THUNK_CACHE_DIR)" "$(HOT_THUNK_CACHE_MAX_GIB)" "ghostty hot thunk cache"; \
		fi; \
		mkdir -p "$(HOT_BUILD_CACHE_DIR)" "$(HOT_GLOBAL_CACHE_DIR)" "$(HOT_THUNK_CACHE_DIR)"; \
		rm -f "$(HOT_LOG)" "$(HOT_PID)" "$(HOT_PORT_FILE)" "$(HOT_CONFIG_FILE)"; \
		cleanup() { "$(MAKE)" hot-stop >/dev/null 2>&1 || true; }; \
		trap cleanup EXIT INT TERM; \
		nohup env \
			DYLD_LIBRARY_PATH="$(ZIG_DYLD_LIBRARY_PATH):$${DYLD_LIBRARY_PATH:-}" \
			ZIG_LIB_DIR="$(ZIG_LIB_DIR)" \
			ZIG_HOT_CACHE_DIR="$(HOT_THUNK_CACHE_DIR)" \
			"$(ZIG)" build $(HOT_ZIG_CACHE_ARGS) run -Dhot=true -Dhot-promotion-workers="$(HOT_TEST_PROMOTION_WORKERS)" -Dhot-promotion-delay-ms="$(HOT_TEST_PROMOTION_DELAY_MS)" $(GHOSTTY_RUN_ARGS) >"$(HOT_LOG)" 2>&1 & \
		run_pid=$$!; \
		echo "$$run_pid" >"$(HOT_PID)"; \
		HOT_CACHE_DIR="$(HOT_BUILD_CACHE_DIR)" \
		HOT_CONFIG_FILE="$(HOT_CONFIG_FILE)" \
		HOT_TEST_PROMOTION_WORKERS="$(HOT_TEST_PROMOTION_WORKERS)" \
		./hot-smoke-test.sh'
.PHONY: hot-test

hot-test-clean: HOT_TEST_CLEAN=1
hot-test-clean: hot-test
.PHONY: hot-test-clean

hot-vscode-ghostty-test: hot-stop $(ZIG_INSTALL_STAMP)
	@CODE_BIN="$(CODE_BIN)" ZIG_BIN="$(ZIG)" ZIG_LIB_DIR="$(ZIG_LIB_DIR)" \
		bash "$(REPO_ROOT)/vendor/zig/tools/hot-vscode/test/vscode_ghostty_live_smoke.sh"
.PHONY: hot-vscode-ghostty-test

hot-compiler-test: $(ZIG_INSTALL_STAMP)
	HOT_TEST_CLEAN="$(HOT_TEST_CLEAN)" HOT_SMOKE_JOBS="$(HOT_SMOKE_JOBS)" HOT_COMPILER_TEST_FILTER="$(HOT_COMPILER_TEST_FILTER)" HOT_COMPILER_SKIP_SMOKES="$(HOT_COMPILER_SKIP_SMOKES)" DYLD_LIBRARY_PATH="$(ZIG_DYLD_LIBRARY_PATH):$$DYLD_LIBRARY_PATH" ./hot-compiler-test.sh
.PHONY: hot-compiler-test

hot-compiler-test-clean: HOT_TEST_CLEAN=1
hot-compiler-test-clean: hot-compiler-test
.PHONY: hot-compiler-test-clean

# Fast inner loop: aggregated hot compiler suite only, no standalone runtime smokes.
hot-compiler-unit-test: $(ZIG_INSTALL_STAMP)
	HOT_TEST_CLEAN="$(HOT_TEST_CLEAN)" HOT_SMOKE_JOBS="$(HOT_SMOKE_JOBS)" HOT_COMPILER_TEST_FILTER="$(HOT_COMPILER_TEST_FILTER)" HOT_COMPILER_SKIP_SMOKES=1 DYLD_LIBRARY_PATH="$(ZIG_DYLD_LIBRARY_PATH):$$DYLD_LIBRARY_PATH" ./hot-compiler-test.sh
.PHONY: hot-compiler-unit-test

hot-compiler-unit-test-clean: HOT_TEST_CLEAN=1
hot-compiler-unit-test-clean: hot-compiler-unit-test
.PHONY: hot-compiler-unit-test-clean

test-hot-fast: hot-compiler-unit-test
.PHONY: test-hot-fast

test-hot-fast-clean: HOT_TEST_CLEAN=1
test-hot-fast-clean: test-hot-fast
.PHONY: test-hot-fast-clean

test-hot-all:
	@bash -lc 'set -euo pipefail; \
		log="/tmp/ghostty-test-hot-all.log"; \
		suite_start=$$SECONDS; \
		rm -f "$$log"; \
		exec > >(tee "$$log") 2>&1; \
		echo "log\t$$log"; \
		phase_start=$$SECONDS; \
		"$(MAKE)" HOT_TEST_CLEAN="$(HOT_TEST_CLEAN)" hot-compiler-test; \
		printf "time\t%s\t%ss\n" "test-hot-all:hot-compiler-test" "$$((SECONDS - phase_start))"; \
		phase_start=$$SECONDS; \
		ghost_log=$$(mktemp "$${TMPDIR:-/tmp}/ghostty-hot-test.XXXXXX"); \
		ghost_time=$$(mktemp "$${TMPDIR:-/tmp}/ghostty-hot-time.XXXXXX"); \
		tb_log=$$(mktemp "$${TMPDIR:-/tmp}/tigerbeetle-hot-test.XXXXXX"); \
		tb_time=$$(mktemp "$${TMPDIR:-/tmp}/tigerbeetle-hot-time.XXXXXX"); \
		( ghost_start=$$SECONDS; \
		  PORT_FILE_TIMEOUT="$${PORT_FILE_TIMEOUT:-900}" "$(MAKE)" HOT_TEST_CLEAN="$(HOT_TEST_CLEAN)" hot-test >"$$ghost_log" 2>&1; \
		  printf "%s\n" "$$((SECONDS - ghost_start))" >"$$ghost_time" ) & \
		ghost_pid=$$!; \
		( tb_start=$$SECONDS; \
		  "$(MAKE)" -C "$(TIGERBEETLE_DIR)" HOT_TEST_CLEAN="$(HOT_TEST_CLEAN)" HOT_ZIG="$(ZIG)" HOT_ZIG_LIB_DIR="$(ZIG_LIB_DIR)" hot-test >"$$tb_log" 2>&1; \
		  printf "%s\n" "$$((SECONDS - tb_start))" >"$$tb_time" ) & \
		tb_pid=$$!; \
		ghost_status=0; \
		tb_status=0; \
		wait "$$ghost_pid" || ghost_status=$$?; \
		wait "$$tb_pid" || tb_status=$$?; \
		cat "$$ghost_log"; \
		cat "$$tb_log"; \
		if [[ "$$ghost_status" -ne 0 || "$$tb_status" -ne 0 ]]; then \
			rm -f "$$ghost_log" "$$ghost_time" "$$tb_log" "$$tb_time"; \
			if [[ "$$ghost_status" -ne 0 ]]; then exit "$$ghost_status"; fi; \
			exit "$$tb_status"; \
		fi; \
		printf "time\t%s\t%ss\n" "test-hot-all:ghostty-hot-test" "$$(cat "$$ghost_time")"; \
		printf "time\t%s\t%ss\n" "test-hot-all:tigerbeetle-hot-test" "$$(cat "$$tb_time")"; \
		printf "time\t%s\t%ss\n" "test-hot-all:downstream-hot-tests" "$$((SECONDS - phase_start))"; \
		rm -f "$$ghost_log" "$$ghost_time" "$$tb_log" "$$tb_time"; \
		printf "time\t%s\t%ss\n" "test-hot-all-total" "$$((SECONDS - suite_start))"'
.PHONY: test-hot-all

test-hot-all-clean: HOT_TEST_CLEAN=1
test-hot-all-clean: test-hot-all
.PHONY: test-hot-all-clean

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
