APP        := SSHTunnel
LIB        := SSHTunnelKit
BUNDLE     := $(APP).app
BUILD      := .build
MODULES    := $(BUILD)/modules
BIN        := $(BUILD)/$(APP)
VERSION    ?= $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
BUILD_VERSION ?= $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist)
DIST_DIR   ?= dist
DIST_STAGING := $(BUILD)/dmg-root
DMG        := $(DIST_DIR)/$(APP)-v$(VERSION)-macos26-arm64.dmg
# `find` (recursive) instead of `wildcard` (one level) so the Model/Services/
# Views subfolders under Sources/$(LIB) are picked up — `swift test` globs
# them via SwiftPM, but this raw-swiftc bundle build does not.
LIB_SRC    := $(shell find Sources/$(LIB) -name '*.swift' | sort)
APP_SRC    := $(shell find Sources/$(APP) -name '*.swift' | sort)
LIB_AR     := $(MODULES)/lib$(LIB).a
LIB_MOD    := $(MODULES)/$(LIB).swiftmodule
ICON_SRC   := assets/icon.png
APP_ICON   := assets/AppIcon.icns
MENU_ICON  := assets/MenuBarIcon.png
MENU_ICON2 := assets/MenuBarIcon@2x.png
RESOURCES  := $(BUNDLE)/Contents/Resources
SDK        := $(shell xcrun --sdk macosx --show-sdk-path)
ARCH       := $(shell uname -m)
TARGET     := $(ARCH)-apple-macosx26.0

.PHONY: all bundle build test dmg install run stop clean

all: bundle

build: $(BIN)

test:
	@swift test

$(LIB_AR) $(LIB_MOD): $(LIB_SRC)
	@mkdir -p $(MODULES)
	@echo "→ compiling $(LIB) ($(TARGET))"
	@xcrun swiftc -sdk $(SDK) -target $(TARGET) -O -parse-as-library \
		-module-name $(LIB) \
		-emit-module -emit-module-path $(LIB_MOD) \
		-emit-library -static -o $(LIB_AR) \
		$(LIB_SRC)

$(BIN): $(APP_SRC) $(LIB_AR) $(LIB_MOD)
	@mkdir -p $(BUILD)
	@echo "→ compiling $(APP) ($(TARGET))"
	@xcrun swiftc -sdk $(SDK) -target $(TARGET) -O -parse-as-library \
		-I $(MODULES) -L $(MODULES) -l$(LIB) \
		$(APP_SRC) -o $@

bundle: build $(APP_ICON) $(MENU_ICON) $(MENU_ICON2)
	@rm -rf $(BUNDLE)
	@mkdir -p $(BUNDLE)/Contents/MacOS $(RESOURCES)
	@cp $(BIN) $(BUNDLE)/Contents/MacOS/$(APP)
	@cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(BUNDLE)/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_VERSION)" $(BUNDLE)/Contents/Info.plist
	@cp $(MENU_ICON) $(RESOURCES)/MenuBarIcon.png
	@cp $(MENU_ICON2) $(RESOURCES)/MenuBarIcon@2x.png
	@cp $(APP_ICON) $(RESOURCES)/AppIcon.icns
	@echo "→ codesign (ad-hoc)"
	@codesign --force --sign - --options runtime $(BUNDLE)
	@echo "✓ built $(BUNDLE)"

dmg: bundle
	@rm -rf $(DIST_STAGING)
	@mkdir -p $(DIST_DIR) $(DIST_STAGING)
	@cp -R $(BUNDLE) $(DIST_STAGING)/$(BUNDLE)
	@ln -s /Applications $(DIST_STAGING)/Applications
	@rm -f $(DMG)
	@hdiutil create -volname "$(APP) v$(VERSION)" \
		-srcfolder $(DIST_STAGING) \
		-ov -format UDZO $(DMG)
	@echo "✓ created $(DMG)"

install: bundle
	@$(MAKE) -s stop
	@for i in 1 2 3 4 5 6 7 8 9 10; do \
		pgrep -x $(APP) >/dev/null || break; \
		sleep 0.2; \
	done
	@rm -rf /Applications/$(BUNDLE)
	@cp -R $(BUNDLE) /Applications/$(BUNDLE)
	@echo "✓ installed /Applications/$(BUNDLE)"

run:
	@$(MAKE) -s stop
	@$(MAKE) -s bundle
	@open $(BUNDLE)
	@echo "✓ launched $(BUNDLE)"

stop:
	@pkill -x $(APP) 2>/dev/null || true

clean:
	@rm -rf $(BUILD) $(BUNDLE)
	@echo "✓ cleaned"
