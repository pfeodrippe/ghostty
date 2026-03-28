PROJECT_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
STOCK_ZIG ?= $(abspath $(PROJECT_DIR)/../zig-stock-0.15.2/stage3-debug/bin/zig)
# Leave empty by default so stock-run exercises the real macOS app-launch path.
STOCK_FLAGS ?=
HOT_ZIG ?= $(abspath $(PROJECT_DIR)/../zig-hot-llvm-0.15.2/stage3-debug-llvm20-stockboot/bin/zig)
HOT_FLAGS ?= -Dhot=true
STOCK_CACHE_DIR ?= $(abspath $(PROJECT_DIR)/.zig-cache-stock)
STOCK_GLOBAL_CACHE_DIR ?= $(abspath $(PROJECT_DIR)/.zig-global-cache-stock)
HOT_CACHE_DIR ?= $(abspath $(PROJECT_DIR)/.zig-cache-hot)
HOT_GLOBAL_CACHE_DIR ?= $(abspath $(PROJECT_DIR)/.zig-global-cache-hot)
HOT_JOBS ?= -j4
HOT_ORPHAN_ROOTS ?= $(HOT_CACHE_DIR) $(notdir $(HOT_CACHE_DIR)) $(HOT_GLOBAL_CACHE_DIR) $(notdir $(HOT_GLOBAL_CACHE_DIR))
HOT_CACHE_RESOLVER ?= $(abspath $(PROJECT_DIR)/tools/resolve_hot_cache_dirs.py)
HOT_RUNNER ?= $(abspath $(PROJECT_DIR)/tools/run_in_own_process_group.sh)
HOT_ORPHAN_KILLER ?= $(abspath $(PROJECT_DIR)/tools/kill_hot_orphans.py)
HOT_APP_PATH ?= $(abspath $(PROJECT_DIR)/zig-out/Ghostty.app/Contents/MacOS/ghostty)
RUN_ARGS ?=

init:
	@echo You probably want to run "zig build" instead.
.PHONY: init

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
		zig-out .zig-cache \
		.zig-cache-stock \
		.zig-global-cache-stock \
		.zig-cache-hot \
		.zig-global-cache-hot \
		macos/build \
		macos/GhosttyKit.xcframework
.PHONY: clean

stock-build:
	@if [ -d macos/build ]; then xattr -cr macos/build; fi
	@if [ -d macos/GhosttyKit.xcframework ]; then xattr -cr macos/GhosttyKit.xcframework; fi
	$(STOCK_ZIG) build $(STOCK_FLAGS) --cache-dir $(STOCK_CACHE_DIR) --global-cache-dir $(STOCK_GLOBAL_CACHE_DIR)
.PHONY: stock-build

stock-run:
	@if [ -d macos/build ]; then xattr -cr macos/build; fi
	@if [ -d macos/GhosttyKit.xcframework ]; then xattr -cr macos/GhosttyKit.xcframework; fi
	$(STOCK_ZIG) build run $(STOCK_FLAGS) --cache-dir $(STOCK_CACHE_DIR) --global-cache-dir $(STOCK_GLOBAL_CACHE_DIR) $(if $(RUN_ARGS),-- $(RUN_ARGS),)
.PHONY: stock-run

hot-build:
	@if [ -d macos/build ]; then xattr -cr macos/build; fi
	@if [ -d macos/GhosttyKit.xcframework ]; then xattr -cr macos/GhosttyKit.xcframework; fi
	@$(HOT_ORPHAN_KILLER) $(HOT_ORPHAN_ROOTS) >/dev/null 2>&1 || true
	@set -eu; \
	eval "$$(python3 $(HOT_CACHE_RESOLVER) $(HOT_CACHE_DIR) $(HOT_GLOBAL_CACHE_DIR))"; \
	$(HOT_RUNNER) $(HOT_ZIG) build $(HOT_FLAGS) --cache-dir "$$HOT_CACHE_DIR" --global-cache-dir "$$HOT_GLOBAL_CACHE_DIR" $(HOT_JOBS)
.PHONY: hot-build

hot-run:
	@if [ -d macos/build ]; then xattr -cr macos/build; fi
	@if [ -d macos/GhosttyKit.xcframework ]; then xattr -cr macos/GhosttyKit.xcframework; fi
	@$(HOT_ORPHAN_KILLER) $(HOT_ORPHAN_ROOTS) >/dev/null 2>&1 || true
	@set -eu; \
	pids="$$(pgrep -f '$(HOT_APP_PATH)' || true)"; \
	if [ -n "$$pids" ]; then \
		kill $$pids >/dev/null 2>&1 || true; \
		sleep 1; \
		still_running="$$(pgrep -f '$(HOT_APP_PATH)' || true)"; \
		if [ -n "$$still_running" ]; then \
			kill -9 $$still_running >/dev/null 2>&1 || true; \
			sleep 1; \
		fi; \
		still_running="$$(pgrep -f '$(HOT_APP_PATH)' || true)"; \
		if [ -n "$$still_running" ]; then \
			printf 'error: stale Ghostty process survived hot-run teardown: %s\n' "$$still_running" >&2; \
			exit 1; \
		fi; \
	fi; \
	rm -f $(PROJECT_DIR)/.nrepl-port; \
	set -eu; \
	eval "$$(python3 $(HOT_CACHE_RESOLVER) $(HOT_CACHE_DIR) $(HOT_GLOBAL_CACHE_DIR))"; \
	$(HOT_RUNNER) $(HOT_ZIG) build run $(HOT_FLAGS) --cache-dir "$$HOT_CACHE_DIR" --global-cache-dir "$$HOT_GLOBAL_CACHE_DIR" $(HOT_JOBS) $(if $(RUN_ARGS),-- $(RUN_ARGS),)
.PHONY: hot-run

hot-test:
	@if [ -d macos/build ]; then xattr -cr macos/build; fi
	@if [ -d macos/GhosttyKit.xcframework ]; then xattr -cr macos/GhosttyKit.xcframework; fi
	@$(HOT_ORPHAN_KILLER) $(HOT_ORPHAN_ROOTS) >/dev/null 2>&1 || true
	@set -eu; \
	eval "$$(python3 $(HOT_CACHE_RESOLVER) $(HOT_CACHE_DIR) $(HOT_GLOBAL_CACHE_DIR))"; \
	$(HOT_RUNNER) $(HOT_ZIG) build test $(HOT_FLAGS) --cache-dir "$$HOT_CACHE_DIR" --global-cache-dir "$$HOT_GLOBAL_CACHE_DIR" $(HOT_JOBS)
.PHONY: hot-test

hot-clean-orphans:
	$(HOT_ORPHAN_KILLER) $(HOT_ORPHAN_ROOTS)
.PHONY: hot-clean-orphans
