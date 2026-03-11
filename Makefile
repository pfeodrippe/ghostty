PROJECT_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
STOCK_ZIG ?= $(abspath $(PROJECT_DIR)/../zig-stock-0.15.2/stage3-debug/bin/zig)
STOCK_FLAGS ?= -Demit-macos-app=false -Demit-xcframework=false
HOT_ZIG ?= $(abspath $(PROJECT_DIR)/../zig-ghostty-hot-0.15.2/stage4-debug-cmake-implfix/bin/zig)
HOT_FLAGS ?= -Dhot=true -Demit-macos-app=false -Demit-xcframework=false
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
	$(HOT_RUNNER) $(HOT_ZIG) build $(HOT_FLAGS)
.PHONY: hot-build

hot-run:
	$(HOT_RUNNER) $(HOT_ZIG) build run $(HOT_FLAGS) $(if $(RUN_ARGS),-- $(RUN_ARGS),)
.PHONY: hot-run

hot-test:
	$(HOT_RUNNER) $(HOT_ZIG) build test $(HOT_FLAGS)
.PHONY: hot-test

hot-clean-orphans:
	$(HOT_ORPHAN_KILLER)
.PHONY: hot-clean-orphans
