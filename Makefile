# Murmur: build a signed .app bundle with SwiftPM (Command Line Tools are enough; Xcode not required).
#
#   make            build build/Murmur.app
#   make install    copy it to ~/Applications (override with INSTALL_DIR=/Applications)
#   make model      download the whisper model + its Neural Engine encoder (MODEL=large-v3-turbo-q5_0)
#   make run        install and launch
#
# Signing: macOS ties Accessibility/Input Monitoring grants to the app's signature. If the
# "Murmur Local Signing" identity exists (scripts/create-signing-cert.sh), it's used so the grants
# survive rebuilds; otherwise the app is signed ad-hoc and loses them on every build.

APP          := .build/app/Murmur.app
SIGN_IDENTITY ?= $(shell security find-certificate -c "Murmur Local Signing" >/dev/null 2>&1 && echo "Murmur Local Signing" || echo -)
INSTALL_DIR  ?= $(HOME)/Applications
MODEL        ?= large-v3-turbo-q5_0

.PHONY: all app install model run clean

all: app

app:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Frameworks $(APP)/Contents/Resources
	cp .build/release/Murmur $(APP)/Contents/MacOS/Murmur
	cp -R .build/release/whisper.framework $(APP)/Contents/Frameworks/
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp Resources/Murmur.icns $(APP)/Contents/Resources/Murmur.icns
	codesign --force --sign "$(SIGN_IDENTITY)" $(APP)/Contents/Frameworks/whisper.framework
	codesign --force --sign "$(SIGN_IDENTITY)" --identifier local.murmur $(APP)
	@echo "Built $(APP)"

install: app
	mkdir -p "$(INSTALL_DIR)"
	-pkill -x Murmur; sleep 0.5
	rm -rf "$(INSTALL_DIR)/Murmur.app"
	cp -R $(APP) "$(INSTALL_DIR)/"
	@echo "Installed to $(INSTALL_DIR)/Murmur.app"

model:
	bash ./scripts/download-model.sh $(MODEL) --coreml

run: install
	open "$(INSTALL_DIR)/Murmur.app"

clean:
	rm -rf .build
