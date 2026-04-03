MIN_XCODE_MAJOR ?= 26
ZIG_SOURCE_DIR := vendor/zig
ZIG_BUILD_DIR ?= .zig-toolchain/build
ZIG_INSTALL_DIR ?= .zig-toolchain/zig-0.15.2
ZIG_STAGE2 := $(abspath $(ZIG_BUILD_DIR))/zig2
ZIG := $(abspath $(ZIG_INSTALL_DIR))/bin/zig
LLVM_PREFIX ?= $(shell brew --prefix llvm@20 2>/dev/null)
LLD_PREFIX ?= $(shell brew --prefix lld@20 2>/dev/null)
ZSTD_PREFIX ?= $(shell brew --prefix zstd 2>/dev/null)
LIBXML2_PREFIX ?= $(shell brew --prefix libxml2 2>/dev/null)
ZLIB_PREFIX ?= $(shell brew --prefix zlib 2>/dev/null)
ZIG_CMAKE_PREFIX_PATH := $(LLVM_PREFIX);$(LLD_PREFIX);$(ZSTD_PREFIX);$(LIBXML2_PREFIX);$(ZLIB_PREFIX)
ZIG_CMAKE_LIBRARY_PATH := $(LLD_PREFIX)/lib;$(LLVM_PREFIX)/lib;$(ZSTD_PREFIX)/lib;$(LIBXML2_PREFIX)/lib;$(ZLIB_PREFIX)/lib
ZIG_LDFLAGS := -L$(LLD_PREFIX)/lib -L$(ZSTD_PREFIX)/lib -L$(LIBXML2_PREFIX)/lib -L$(ZLIB_PREFIX)/lib
ZIG_CPPFLAGS := -I$(LLD_PREFIX)/include -I$(ZSTD_PREFIX)/include -I$(LIBXML2_PREFIX)/include -I$(ZLIB_PREFIX)/include

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
			-DCMAKE_PREFIX_PATH="$(ZIG_CMAKE_PREFIX_PATH)" \
			-DCMAKE_LIBRARY_PATH="$(ZIG_CMAKE_LIBRARY_PATH)" \
			-DCMAKE_INSTALL_PREFIX="$(abspath $(ZIG_INSTALL_DIR))"
	cmake --build "$(ZIG_BUILD_DIR)" --target zig2

$(ZIG): $(ZIG_STAGE2)
	cmake --build "$(ZIG_BUILD_DIR)" --target install

stock-run: $(ZIG)
	$(ZIG) build run
.PHONY: stock-run

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
