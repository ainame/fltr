.PHONY: all release install linux profile benchmark

all: release install

release:
	swift build --traits MmapBuffer -c release
install:
	cp ./.build/release/fltr ~/.local/bin/

# Linux static build with mimalloc and increased stack size (aarch64 by default)
# Builds mimalloc 3.0.10 via direct compilation (no CMake), links it with --whole-archive to replace musl's allocator
# Stack size: 0x80000 (512 KiB)
# Usage: make linux [ARCH=x86_64]
MIMALLOC_VERSION ?= 3.0.10
ARCH ?= aarch64
SWIFT_SDK_PATH := $(shell swift sdk configure --show-configuration swift-6.2.3-RELEASE_static-linux-0.0.1 | grep "sdkRootPath:" | head -1 | awk '{print $$2}')

linux:
	@if [ ! -f mimalloc-build-$(ARCH)/libmimalloc.a ]; then \
		echo "Building mimalloc $(MIMALLOC_VERSION) for $(ARCH)..."; \
		if [ ! -d mimalloc-$(MIMALLOC_VERSION) ]; then \
			curl -sSfL "https://github.com/microsoft/mimalloc/archive/refs/tags/v$(MIMALLOC_VERSION).tar.gz" | tar xz; \
		fi; \
		mkdir -p mimalloc-build-$(ARCH); \
		clang --target=$(ARCH)-unknown-linux-musl \
			--sysroot=$(SWIFT_SDK_PATH) \
			-O3 -DNDEBUG -DMI_LIBC_MUSL=1 -DMI_STATIC_LIB \
			-fvisibility=hidden -fno-builtin-malloc \
			-Imimalloc-$(MIMALLOC_VERSION)/include \
			-c mimalloc-$(MIMALLOC_VERSION)/src/alloc.c \
			   mimalloc-$(MIMALLOC_VERSION)/src/alloc-aligned.c \
			   mimalloc-$(MIMALLOC_VERSION)/src/alloc-posix.c \
			   mimalloc-$(MIMALLOC_VERSION)/src/arena.c \
			   mimalloc-$(MIMALLOC_VERSION)/src/arena-meta.c \
			   mimalloc-$(MIMALLOC_VERSION)/src/bitmap.c \
			   mimalloc-$(MIMALLOC_VERSION)/src/heap.c \
			   mimalloc-$(MIMALLOC_VERSION)/src/init.c \
			   mimalloc-$(MIMALLOC_VERSION)/src/libc.c \
			   mimalloc-$(MIMALLOC_VERSION)/src/options.c \
			   mimalloc-$(MIMALLOC_VERSION)/src/os.c \
			   mimalloc-$(MIMALLOC_VERSION)/src/page.c \
			   mimalloc-$(MIMALLOC_VERSION)/src/page-map.c \
			   mimalloc-$(MIMALLOC_VERSION)/src/random.c \
			   mimalloc-$(MIMALLOC_VERSION)/src/stats.c \
			   mimalloc-$(MIMALLOC_VERSION)/src/prim/prim.c && \
		ar rcs mimalloc-build-$(ARCH)/libmimalloc.a *.o; \
	fi
	swift build -c release --product fltr --swift-sdk $(ARCH)-swift-linux-musl \
		-Xlinker -z -Xlinker stack-size=0x80000 \
		-Xlinker --whole-archive \
		-Xlinker ./mimalloc-build-$(ARCH)/libmimalloc.a \
		-Xlinker --no-whole-archive

# Usage: make profile INPUT=./input.txt ARGS="--query foo"
profile: release
	@if [ -n "$(INPUT)" ]; then \
		INPUT_ARG="--input $(INPUT)"; \
	else \
		INPUT_ARG=""; \
	fi; \
	scripts/profile_xctrace.sh $$INPUT_ARG -- $(ARGS)

# Usage: make benchmark COUNT=500000 MODE=all RUNS=5 WARMUP=2 SEED=1337
benchmark: release
	swift build -c release --package-path Benchmarks --target matcher-benchmark
	Benchmarks/.build/release/matcher-benchmark \
		--count $(COUNT) \
		--mode $(MODE) \
		--runs $(RUNS) \
		--warmup $(WARMUP) \
		--seed $(SEED)

COUNT ?= 500000
MODE ?= all
RUNS ?= 5
WARMUP ?= 2
SEED ?= 1337
