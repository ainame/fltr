.PHONNY: all

all: release install

release:
	swift build -c release
install:
	cp ./.build/release/fltr ~/.local/bin/
