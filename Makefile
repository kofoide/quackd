# quackd — https://github.com/kofoide/quackd
#
#   make install          install the quackd CLI to $(BINDIR)
#   make install-app      build Quackd.app and install it to $(APPDIR), then open it
#   make uninstall        remove the CLI (leaves your config, log and service alone)
#   make uninstall-app    quit and remove Quackd.app
#   make test             run the test suite (integration tests need duckdb)
#   make lint             shellcheck the shell scripts
#   make dist             build release artifacts in build/dist/
#   make clean            remove build/

PREFIX  ?= $(HOME)/.local
BINDIR  ?= $(PREFIX)/bin
APPDIR  ?= $(HOME)/Applications
BUILD   := build
VERSION := $(shell sed -n 's/^QUACKD_VERSION="\(.*\)"$$/\1/p' bin/quackd)
SHELL_SCRIPTS := bin/quackd app/build.sh tests/run.sh scripts/update-tap.sh

.PHONY: help install uninstall app install-app uninstall-app test lint dist clean version

help:
	@sed -n 's/^#   make/  make/p' Makefile

version:
	@echo $(VERSION)

install:
	install -d "$(BINDIR)"
	install -m 755 bin/quackd "$(BINDIR)/quackd"
	@echo "Installed $(BINDIR)/quackd"
	@case ":$$PATH:" in *":$(BINDIR):"*) ;; *) echo "Note: $(BINDIR) is not on your PATH. Add it, e.g.: echo 'export PATH=\"$(BINDIR):\$$PATH\"' >> ~/.zshrc";; esac

uninstall:
	rm -f "$(BINDIR)/quackd"

app:
	app/build.sh "$(BUILD)"

install-app: app
	-pkill -x QuackdMenu || true
	install -d "$(APPDIR)"
	rm -rf "$(APPDIR)/Quackd.app"
	cp -R "$(BUILD)/Quackd.app" "$(APPDIR)/Quackd.app"
	open "$(APPDIR)/Quackd.app"
	@echo "Installed and opened $(APPDIR)/Quackd.app"

uninstall-app:
	-pkill -x QuackdMenu || true
	rm -rf "$(APPDIR)/Quackd.app"

test:
	tests/run.sh

lint:
	shellcheck $(SHELL_SCRIPTS)

# Release artifacts: the CLI script and a zipped (unsigned) app.
dist: app
	rm -rf "$(BUILD)/dist"
	install -d "$(BUILD)/dist"
	install -m 755 bin/quackd "$(BUILD)/dist/quackd"
	ditto -c -k --keepParent "$(BUILD)/Quackd.app" "$(BUILD)/dist/Quackd-$(VERSION).zip"
	cd "$(BUILD)/dist" && shasum -a 256 quackd "Quackd-$(VERSION).zip" > SHA256SUMS
	@cat "$(BUILD)/dist/SHA256SUMS"

clean:
	rm -rf "$(BUILD)"
