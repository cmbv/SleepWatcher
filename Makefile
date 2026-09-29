#
#	Makefile for sleepwatcher 3
#
#	make                  arm64 binary in build/ (macOS 27 is Apple silicon only)
#	make ARCHS="arm64 x86_64"   universal binary for older Intel Macs
#	make install          binary to $(PREFIX)/bin (default ~/.local/bin, no sudo)
#	make install-agent    LaunchAgent running ~/.sleep and ~/.wakeup
#	make uninstall-agent  unload and remove it
#	make test             smoke tests (no sleeping involved)
#

PREFIX     ?= $(HOME)/.local
BINDIR      = $(PREFIX)/bin
MIN_MACOS   = 13.0
ARCHS      ?= arm64
LABEL       = local.sleepwatcher
AGENT       = $(HOME)/Library/LaunchAgents/$(LABEL).plist
SOURCES     = $(wildcard Sources/sleepwatcher/*.swift)
SWIFTFLAGS  = -O -swift-version 6 -framework IOKit -framework AppKit -framework Security

build/sleepwatcher: $(SOURCES) Makefile
	mkdir -p build
	for arch in $(ARCHS); do \
		swiftc $(SWIFTFLAGS) -target $$arch-apple-macos$(MIN_MACOS) $(SOURCES) -o build/sleepwatcher-$$arch || exit 1; \
	done
	lipo -create $(foreach arch,$(ARCHS),build/sleepwatcher-$(arch)) -output $@
	rm -f $(foreach arch,$(ARCHS),build/sleepwatcher-$(arch))
	codesign --force --sign - --identifier sleepwatcher $@

install: build/sleepwatcher
	mkdir -p $(BINDIR)
	install -m 755 build/sleepwatcher $(BINDIR)/sleepwatcher

install-agent: install
	mkdir -p $(dir $(AGENT))
	sed -e 's|@BINDIR@|$(BINDIR)|g' -e 's|@HOME@|$(HOME)|g' -e 's|@LABEL@|$(LABEL)|g' \
		config/sleepwatcher.plist.in > $(AGENT)
	launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null || true
	launchctl bootstrap gui/$$(id -u) $(AGENT)
	@echo "Loaded $(AGENT); log: ~/Library/Logs/sleepwatcher.log"

uninstall-agent:
	launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null || true
	rm -f $(AGENT)

test: build/sleepwatcher
	./tests/smoke.sh build/sleepwatcher

clean:
	rm -rf build .build

.PHONY: install install-agent uninstall-agent test clean
