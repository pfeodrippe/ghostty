PROJECT_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
STOCK_ZIG ?= $(abspath $(PROJECT_DIR)/../zig-stock-0.15.2/stage3-debug/bin/zig)
# Leave empty by default so stock-run exercises the real macOS app-launch path.
STOCK_FLAGS ?=
STOCK_CACHE_DIR ?= $(abspath $(PROJECT_DIR)/.zig-cache-stock)
STOCK_GLOBAL_CACHE_DIR ?= $(abspath $(PROJECT_DIR)/.zig-global-cache-stock)
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
