.PHONY: all release install profile benchmark

all: release install

release:
	swift build -c release
install:
	cp ./.build/release/fltr ~/.local/bin/

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
	swift build -c release --target matcher-benchmark
	.build/release/matcher-benchmark \
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
