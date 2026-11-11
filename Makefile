.DEFAULT_GOAL := build
GHC ?= $(shell command -v ghc || echo "$(HOME)/.ghcup/bin/ghc")
CABAL ?= $(shell command -v cabal || echo "$(HOME)/.ghcup/bin/cabal")
ifeq ($(strip $(DEVELOPER_DIR)),)
ifeq ($(shell xcode-select -p),/Library/Developer/CommandLineTools)
ifneq ($(wildcard /Applications/Xcode.app/Contents/Developer),)
DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
endif
endif
endif
ifneq ($(DEVELOPER_DIR),)
export DEVELOPER_DIR
endif
SWIFTC ?= xcrun --sdk macosx swiftc
export MACOSX_DEPLOYMENT_TARGET := 15.0
ARCH := $(shell uname -m)
SWIFT_FLAGS := -swift-version 6 -target $(ARCH)-apple-macos15.0 -module-cache-path build/swift-cache
CABAL_FLAGS := --with-compiler="$(GHC)" -O2 --disable-executable-dynamic
APP := build/USBviewHS.app
ENGINE := $(APP)/Contents/Helpers/usbview-hs
UI := $(APP)/Contents/MacOS/USBviewHS
STRINGS := $(APP)/Contents/Resources/en.lproj/Localizable.strings
HS := $(wildcard engine/*.hs)
SWIFT := $(wildcard app/*.swift)

.PHONY: build run tree dump watch descriptors test
build: $(APP)/Contents/_CodeSignature/CodeResources

$(ENGINE): $(HS) usbview-hs.cabal Makefile
	@mkdir -p $(@D)
	"$(CABAL)" build $(CABAL_FLAGS) exe:usbview-hs
	install -m 755 "$$("$(CABAL)" list-bin $(CABAL_FLAGS) exe:usbview-hs)" "$@"
	codesign --force --sign - $@

$(UI): $(SWIFT) Makefile
	@mkdir -p $(@D)
	$(SWIFTC) $(SWIFT_FLAGS) -O $(SWIFT) -o $@

$(APP)/Contents/Info.plist: app/Info.plist
	@mkdir -p $(@D)
	cp $< $@

$(STRINGS): app/en.lproj/Localizable.strings
	@mkdir -p $(@D)
	cp $< $@

$(APP)/Contents/Resources/LICENSE: LICENSE
	@mkdir -p $(@D)
	cp $< $@

$(APP)/Contents/_CodeSignature/CodeResources: $(ENGINE) $(UI) $(APP)/Contents/Info.plist $(STRINGS) $(APP)/Contents/Resources/LICENSE
	codesign --force --sign - $(APP)

run: build
	open $(APP)

tree dump watch descriptors:
	@$(MAKE) --no-print-directory build >&2
	@$(UI) $(if $(filter tree,$@),--dump-tree,$(if $(filter dump,$@),--dump-json,--$@))

build/test-app: app/Localization.swift app/Snapshot.swift app/Descriptors.swift app/Reconnect.swift app/Inspector.swift tests/AppTest.swift Makefile
	@mkdir -p build
	$(SWIFTC) $(SWIFT_FLAGS) $(filter %.swift,$^) -o $@

test: build build/test-app
	"$(CABAL)" test $(CABAL_FLAGS) test:topology --test-show-details=direct
	build/test-app "$(UI)"
	codesign --verify --deep --strict $(APP)
