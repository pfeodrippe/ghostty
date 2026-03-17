PROJECT_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
STOCK_ZIG ?= $(abspath $(PROJECT_DIR)/../zig-stock-0.15.2/stage3-debug/bin/zig)
STOCK_FLAGS ?= -Demit-macos-app=false -Demit-xcframework=false
HOT_ZIG_CURRENT := $(abspath $(PROJECT_DIR)/../zig-ghostty-hot-0.15.2/stage4-debug-cmake-implfix-current/bin/zig)
HOT_ZIG_FALLBACK := $(abspath $(PROJECT_DIR)/../zig-ghostty-hot-0.15.2/stage4-debug-cmake-implfix/bin/zig)
HOT_ZIG ?= $(if $(wildcard $(HOT_ZIG_CURRENT)),$(HOT_ZIG_CURRENT),$(HOT_ZIG_FALLBACK))
HOT_FLAGS ?= -Dhot=true -Demit-macos-app=false -Demit-xcframework=false
HOT_CACHE_DIR ?= $(abspath $(PROJECT_DIR)/.zig-cache-hot)
HOT_GLOBAL_CACHE_DIR ?= $(abspath $(PROJECT_DIR)/.zig-global-cache-hot)
HOT_JOBS ?= -j4
HOT_ORPHAN_ROOTS ?= $(HOT_CACHE_DIR) $(notdir $(HOT_CACHE_DIR)) $(HOT_GLOBAL_CACHE_DIR) $(notdir $(HOT_GLOBAL_CACHE_DIR))
HOT_CACHE_RESOLVER ?= $(abspath $(PROJECT_DIR)/tools/resolve_hot_cache_dirs.py)
STAGE4_ZIG ?= $(HOT_ZIG)
STAGE4_FLAGS ?= $(STOCK_FLAGS)
STAGE4_BACKEND_FLAGS ?= -Duse-llvm=false -Duse-lld=false
STAGE4_CACHE_DIR ?= $(abspath $(PROJECT_DIR)/.zig-cache-stage4)
STAGE4_GLOBAL_CACHE_DIR ?= $(abspath $(PROJECT_DIR)/.zig-global-cache-stage4)
STAGE4_JOBS ?= -j4
STAGE4_ORPHAN_ROOTS ?= $(STAGE4_CACHE_DIR) $(notdir $(STAGE4_CACHE_DIR)) $(STAGE4_GLOBAL_CACHE_DIR) $(notdir $(STAGE4_GLOBAL_CACHE_DIR))
STOCK_APP ?= $(abspath $(PROJECT_DIR)/macos/build/Debug/Ghostty.app)
STOCK_APP_BIN ?= $(STOCK_APP)/Contents/MacOS/ghostty
RUN_ARGS ?=
HOT_RUNNER ?= $(abspath $(PROJECT_DIR)/tools/run_in_own_process_group.sh)
HOT_ORPHAN_KILLER ?= $(abspath $(PROJECT_DIR)/tools/kill_hot_orphans.py)

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
		.zig-cache-hot \
		.zig-global-cache-hot \
		.zig-cache-stage4 \
		.zig-global-cache-stage4 \
		.zig-hot \
		macos/build \
		macos/GhosttyKit.xcframework
.PHONY: clean

stock-build:
	$(STOCK_ZIG) build $(STOCK_FLAGS)
.PHONY: stock-build

stock-run:
	$(STOCK_ZIG) build run $(STOCK_FLAGS) $(if $(RUN_ARGS),-- $(RUN_ARGS),)
.PHONY: stock-run

stock-open:
	@activator_pid=''; \
	( \
		for _ in $$(seq 1 120); do \
			pid=$$(ps -Ao pid=,command= | awk -v app="$(STOCK_APP_BIN)" '$$2 == app { print $$1; exit }'); \
			if [ -n "$$pid" ]; then \
				osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $$pid) to true" >/dev/null 2>&1 || true; \
				exit 0; \
			fi; \
			sleep 1; \
		done; \
	) & activator_pid=$$!; \
	$(STOCK_ZIG) build run $(STOCK_FLAGS) $(if $(RUN_ARGS),-- $(RUN_ARGS),); \
	status=$$?; \
	kill $$activator_pid >/dev/null 2>&1 || true; \
	wait $$activator_pid >/dev/null 2>&1 || true; \
	exit $$status
.PHONY: stock-open

stock-test:
	$(STOCK_ZIG) build test $(STOCK_FLAGS)
.PHONY: stock-test

hot-build:
	@$(HOT_ORPHAN_KILLER) $(HOT_ORPHAN_ROOTS) >/dev/null 2>&1 || true
	@set -eu; \
	eval "$$(python3 $(HOT_CACHE_RESOLVER) $(HOT_CACHE_DIR) $(HOT_GLOBAL_CACHE_DIR))"; \
	$(HOT_RUNNER) $(HOT_ZIG) build $(HOT_FLAGS) --cache-dir "$$HOT_CACHE_DIR" --global-cache-dir "$$HOT_GLOBAL_CACHE_DIR" $(HOT_JOBS)
.PHONY: hot-build

hot-run:
	@$(HOT_ORPHAN_KILLER) $(HOT_ORPHAN_ROOTS) >/dev/null 2>&1 || true
	@set -eu; \
	eval "$$(python3 $(HOT_CACHE_RESOLVER) $(HOT_CACHE_DIR) $(HOT_GLOBAL_CACHE_DIR))"; \
	$(HOT_RUNNER) $(HOT_ZIG) build run $(HOT_FLAGS) --cache-dir "$$HOT_CACHE_DIR" --global-cache-dir "$$HOT_GLOBAL_CACHE_DIR" $(HOT_JOBS) $(if $(RUN_ARGS),-- $(RUN_ARGS),)
.PHONY: hot-run

hot-test:
	@$(HOT_ORPHAN_KILLER) $(HOT_ORPHAN_ROOTS) >/dev/null 2>&1 || true
	@set -eu; \
	eval "$$(python3 $(HOT_CACHE_RESOLVER) $(HOT_CACHE_DIR) $(HOT_GLOBAL_CACHE_DIR))"; \
	$(HOT_RUNNER) $(HOT_ZIG) build test $(HOT_FLAGS) --cache-dir "$$HOT_CACHE_DIR" --global-cache-dir "$$HOT_GLOBAL_CACHE_DIR" $(HOT_JOBS)
.PHONY: hot-test

stage4-build:
	@$(HOT_ORPHAN_KILLER) $(STAGE4_ORPHAN_ROOTS) >/dev/null 2>&1 || true
	@set -eu; \
	eval "$$(python3 $(HOT_CACHE_RESOLVER) $(STAGE4_CACHE_DIR) $(STAGE4_GLOBAL_CACHE_DIR))"; \
	$(HOT_RUNNER) $(STAGE4_ZIG) build $(STAGE4_FLAGS) $(STAGE4_BACKEND_FLAGS) --cache-dir "$$HOT_CACHE_DIR" --global-cache-dir "$$HOT_GLOBAL_CACHE_DIR" $(STAGE4_JOBS)
.PHONY: stage4-build

stage4-run:
	@$(HOT_ORPHAN_KILLER) $(STAGE4_ORPHAN_ROOTS) >/dev/null 2>&1 || true
	@set -eu; \
	eval "$$(python3 $(HOT_CACHE_RESOLVER) $(STAGE4_CACHE_DIR) $(STAGE4_GLOBAL_CACHE_DIR))"; \
	$(HOT_RUNNER) $(STAGE4_ZIG) build run $(STAGE4_FLAGS) $(STAGE4_BACKEND_FLAGS) --cache-dir "$$HOT_CACHE_DIR" --global-cache-dir "$$HOT_GLOBAL_CACHE_DIR" $(STAGE4_JOBS) $(if $(RUN_ARGS),-- $(RUN_ARGS),)
.PHONY: stage4-run

hot-clean-orphans:
	$(HOT_ORPHAN_KILLER) $(HOT_ORPHAN_ROOTS)
.PHONY: hot-clean-orphans
