PREFIX ?= $(HOME)/.local
BIN := git-credential-code-storage
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
ARCHS ?= arm64 x86_64
SWIFT_BUILD := swift build -c release $(foreach arch,$(ARCHS),--arch $(arch))
BUILD = $(shell $(SWIFT_BUILD) --show-bin-path)/$(BIN)
# Code signing identity. The default "-" is an ad-hoc signature (see README).
CODESIGN_IDENTITY ?= -
DIST := dist/$(BIN)-$(VERSION)-macos-universal

.PHONY: build install uninstall dist clean

build:
	$(SWIFT_BUILD)
	codesign --force --sign "$(CODESIGN_IDENTITY)" --identifier com.sj26.$(BIN) $(BUILD)

install: build
	install -d $(PREFIX)/bin
	install -m 0755 $(BUILD) $(PREFIX)/bin/$(BIN)

uninstall:
	rm -f $(PREFIX)/bin/$(BIN)

dist: build
	rm -rf $(DIST) $(DIST).tar.gz
	mkdir -p $(DIST)
	cp $(BUILD) README.md LICENSE $(DIST)/
	COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -C dist -czf $(DIST).tar.gz $(notdir $(DIST))
	cd dist && shasum -a 256 $(notdir $(DIST)).tar.gz > $(notdir $(DIST)).tar.gz.sha256
	rm -rf $(DIST)

clean:
	rm -rf .build dist
