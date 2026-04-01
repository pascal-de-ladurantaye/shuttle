SHELL := /bin/bash
.DEFAULT_GOAL := help

SHUTTLE_PROFILE ?= prod

export SHUTTLE_PROFILE
export INSTALL_APPLICATIONS_DIR
export OPEN_APP
export DELETE_APP_DATA
export QUIT_RUNNING_APP
export CREATE_ZIP
export ADHOC_SIGN
export EMBED_GHOSTTY_RESOURCES
export NOTARY_PROFILE
export SIGN_IDENTITY
export SIGN_COMPANION_CLI
export BUILD_NUMBER
export DIST_DIR

.PHONY: help ghostty build test icon package package-dev open open-dev open-packaged open-packaged-dev install install-dev uninstall uninstall-dev sign-notarize sign-notarize-dev

help:
	@printf "Shuttle make targets:\n"
	@printf "  make ghostty              Download GhosttyKit if needed\n"
	@printf "  make build                Run swift build\n"
	@printf "  make test                 Run swift test\n"
	@printf "  make icon                 Generate the .icns app icon into dist/generated/\n"
	@printf "  make open                 Run Shuttle from source with swift run (profile=%s)\n" "$(SHUTTLE_PROFILE)"
	@printf "  make open-dev             Run Shuttle Dev from source without installing\n"
	@printf "  make package              Build the packaged app bundle for the current profile\n"
	@printf "  make package-dev          Build Shuttle Dev.app into dist/macos-dev/\n"
	@printf "  make open-packaged        Package and open the packaged app for the current profile\n"
	@printf "  make open-packaged-dev    Package and open Shuttle Dev.app\n"
	@printf "  make install              Package and install the current profile app into /Applications\n"
	@printf "  make install-dev          Package and install /Applications/Shuttle Dev.app\n"
	@printf "  make uninstall            Remove the installed app for the current profile and optionally its app data\n"
	@printf "  make uninstall-dev        Remove /Applications/Shuttle Dev.app and optionally its app data\n"
	@printf "  make sign-notarize        Run the Developer ID + notarization flow for the current profile\n"
	@printf "\nExamples:\n"
	@printf "  make open\n"
	@printf "  make open-dev\n"
	@printf "  make install\n"
	@printf "  make install-dev INSTALL_APPLICATIONS_DIR=$$HOME/Applications OPEN_APP=0\n"
	@printf "  make uninstall DELETE_APP_DATA=1\n"

ghostty:
	./scripts/download-prebuilt-ghosttykit.sh

build:
	swift build

test:
	swift test

icon:
	mkdir -p dist/generated
	./scripts/build-macos-app-icon.sh dist/generated/Shuttle.icns

package:
	./scripts/package-macos-app.sh

package-dev:
	@$(MAKE) package SHUTTLE_PROFILE=dev

open:
	swift run ShuttleApp

open-dev:
	@$(MAKE) open SHUTTLE_PROFILE=dev

open-packaged:
	./scripts/open-packaged-app.sh

open-packaged-dev:
	@$(MAKE) open-packaged SHUTTLE_PROFILE=dev

install:
	./scripts/install-macos-app.sh

install-dev:
	@$(MAKE) install SHUTTLE_PROFILE=dev

uninstall:
	./scripts/uninstall-macos-app.sh

uninstall-dev:
	@$(MAKE) uninstall SHUTTLE_PROFILE=dev

sign-notarize:
	./scripts/sign-and-notarize-macos-app.sh

sign-notarize-dev:
	@$(MAKE) sign-notarize SHUTTLE_PROFILE=dev
