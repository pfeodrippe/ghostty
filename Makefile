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
HOT_PRUNE_BUILD_CACHE ?= 1
HOT_ORPHAN_ROOTS ?= $(HOT_CACHE_DIR) $(notdir $(HOT_CACHE_DIR)) $(HOT_GLOBAL_CACHE_DIR) $(notdir $(HOT_GLOBAL_CACHE_DIR))
HOT_CACHE_RESOLVER ?= $(abspath $(PROJECT_DIR)/tools/resolve_hot_cache_dirs.py)
HOT_RUNNER ?= $(abspath $(PROJECT_DIR)/tools/run_in_own_process_group.sh)
HOT_ORPHAN_KILLER ?= $(abspath $(PROJECT_DIR)/tools/kill_hot_orphans.py)
HOT_LAUNCHER ?= $(abspath $(PROJECT_DIR)/tools/hot_run_app.py)
HOT_APP_BUNDLE ?= $(abspath $(PROJECT_DIR)/zig-out/Ghostty.app)
HOT_RESOURCES_DIR ?= $(abspath $(PROJECT_DIR)/zig-out/share/ghostty)
HOT_MANIFEST ?= $(abspath $(PROJECT_DIR)/zig-out/share/ghostty/GhosttyKit.hot.json)
HOT_ZIG_LIB_DIR ?= $(abspath $(PROJECT_DIR)/../zig-hot-llvm-0.15.2/lib)
HOT_RUN_DEFAULT_ARGS ?= --config-default-files=false --window-save-state=never --window-vsync=false
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

hot-prune-generated:
	rm -rf \
		$(PROJECT_DIR)/.zig-cache-hot-recover-* \
		$(PROJECT_DIR)/.zig-hot \
		/tmp/ghostty-hot-run-app.*
	@if [ "$(HOT_PRUNE_BUILD_CACHE)" = "1" ]; then \
		rm -rf "$(HOT_CACHE_DIR)" "$(HOT_GLOBAL_CACHE_DIR)"; \
	fi
.PHONY: hot-prune-generated

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

hot-build: hot-prune-generated
	@if [ -d macos/build ]; then xattr -cr macos/build; fi
	@if [ -d macos/GhosttyKit.xcframework ]; then xattr -cr macos/GhosttyKit.xcframework; fi
	@$(HOT_ORPHAN_KILLER) $(HOT_ORPHAN_ROOTS) >/dev/null 2>&1 || true
	@set -eu; \
	eval "$$(python3 $(HOT_CACHE_RESOLVER) $(HOT_CACHE_DIR) $(HOT_GLOBAL_CACHE_DIR))"; \
	$(HOT_RUNNER) $(HOT_ZIG) build $(HOT_FLAGS) --cache-dir "$$HOT_CACHE_DIR" --global-cache-dir "$$HOT_GLOBAL_CACHE_DIR" $(HOT_JOBS)
.PHONY: hot-build

hot-run: hot-build
	@set -eu; \
	run_args='$(strip $(RUN_ARGS))'; \
	if [ -z "$$run_args" ]; then \
		run_args='$(HOT_RUN_DEFAULT_ARGS)'; \
	fi; \
	python3 $(HOT_LAUNCHER) \
		--repo-root $(PROJECT_DIR) \
		--app-bundle $(HOT_APP_BUNDLE) \
		--resources-dir $(HOT_RESOURCES_DIR) \
		--port-file $(PROJECT_DIR)/.nrepl-port \
		--hot-compiler $(HOT_ZIG) \
		--hot-workspace $(PROJECT_DIR)/.zig-hot \
		--hot-lib-dir $(HOT_ZIG_LIB_DIR) \
		--hot-manifest $(HOT_MANIFEST) \
		--run-args "$$run_args"
.PHONY: hot-run

hot-test: hot-prune-generated
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
