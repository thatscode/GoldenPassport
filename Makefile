# Build outputs live outside ~/Documents: iCloud Drive adds extended attributes
# that make codesign fail, and would also sync hundreds of MB of artifacts.
BUILD_ROOT ?= $(HOME)/Library/Caches/GoldenPassport-build
SWIFT = xcrun swift
SWIFT_FLAGS = --scratch-path "$(BUILD_ROOT)/swiftpm"

.PHONY: test dev release beta run-dev clean

test:
	$(SWIFT) test $(SWIFT_FLAGS)

dev:
	BUILD_ROOT="$(BUILD_ROOT)" scripts/build-app.sh dev

release:
	BUILD_ROOT="$(BUILD_ROOT)" scripts/build-app.sh release

run-dev: dev
	open "$(BUILD_ROOT)/dev/GoldenPassport Dev.app"

clean:
	rm -rf "$(BUILD_ROOT)"

beta:
	BUILD_ROOT="$(BUILD_ROOT)" scripts/package-beta.sh
