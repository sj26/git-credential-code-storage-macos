PREFIX ?= $(HOME)/.local
BIN := git-credential-code-storage
ARCHS ?= arm64 x86_64
SWIFT_BUILD := swift build -c release $(foreach arch,$(ARCHS),--arch $(arch))
BUILD = $(shell $(SWIFT_BUILD) --show-bin-path)/$(BIN)
DIST := dist/$(BIN)-macos-universal

# Code signing identity. The default "-" is an ad-hoc signature (see README).
# Releases use a Developer ID identity, which also enables notarization.
CODESIGN_IDENTITY ?= -
NOTARY_PROFILE ?= code-storage
ifeq ($(CODESIGN_IDENTITY),-)
CODESIGN_FLAGS := --options runtime
DIST_DEPS := build
else
CODESIGN_FLAGS := --options runtime --timestamp
DIST_DEPS := notarize
endif

.PHONY: build install uninstall notarize dist clean

build:
	$(SWIFT_BUILD)
	codesign --force --sign "$(CODESIGN_IDENTITY)" $(CODESIGN_FLAGS) --identifier com.sj26.$(BIN) $(BUILD)

install: build
	install -d $(PREFIX)/bin
	install -m 0755 $(BUILD) $(PREFIX)/bin/$(BIN)

uninstall:
	rm -f $(PREFIX)/bin/$(BIN)

# Bare executables can't be stapled; Gatekeeper finds the ticket online.
notarize: build
	rm -f .build/$(BIN).zip
	ditto -c -k $(BUILD) .build/$(BIN).zip
	xcrun notarytool submit .build/$(BIN).zip --keychain-profile "$(NOTARY_PROFILE)" --wait | tee .build/notary.log
	grep -q "status: Accepted" .build/notary.log
	rm -f .build/$(BIN).zip .build/notary.log

dist: $(DIST_DEPS)
	rm -rf $(DIST) $(DIST).tar.gz
	mkdir -p $(DIST)
	cp $(BUILD) README.md LICENSE $(DIST)/
	COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -C dist -czf $(DIST).tar.gz $(notdir $(DIST))
	cd dist && shasum -a 256 $(notdir $(DIST)).tar.gz > $(notdir $(DIST)).tar.gz.sha256
	rm -rf $(DIST)

clean:
	rm -rf .build dist
