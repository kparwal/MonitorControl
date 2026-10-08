APP      := build/MonitorControl.app
PREFIX   ?= $(HOME)/.local
APPS_DIR ?= $(HOME)/Applications

.PHONY: all app cli install uninstall clean

all: app cli

cli:
	swift build -c release --product monitorctl

app:
	swift build -c release --product MonitorControl
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp .build/release/MonitorControl $(APP)/Contents/MacOS/MonitorControl
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign - --identifier dev.monitorctl.MonitorControl $(APP)

install: all
	mkdir -p $(PREFIX)/bin $(APPS_DIR)
	install -m 755 .build/release/monitorctl $(PREFIX)/bin/monitorctl
	rm -rf $(APPS_DIR)/MonitorControl.app
	cp -R $(APP) $(APPS_DIR)/MonitorControl.app
	@echo "installed: $(PREFIX)/bin/monitorctl and $(APPS_DIR)/MonitorControl.app"

uninstall:
	rm -f $(PREFIX)/bin/monitorctl
	rm -rf $(APPS_DIR)/MonitorControl.app

clean:
	rm -rf .build build
