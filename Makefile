# Build outputs live outside ~/Documents: iCloud Drive adds extended attributes
# that make codesign fail, and would also sync hundreds of MB of artifacts.
BUILD_ROOT ?= $(HOME)/Library/Caches/GoldenPassport-build
SWIFT = xcrun swift
SWIFT_FLAGS = --scratch-path "$(BUILD_ROOT)/swiftpm"

.PHONY: test check dev release package beta run-dev clean

test:
	$(SWIFT) test $(SWIFT_FLAGS)

# What CI runs, on this Mac; run before every release (scripts/check.sh)
check:
	BUILD_ROOT="$(BUILD_ROOT)" scripts/check.sh

dev:
	BUILD_ROOT="$(BUILD_ROOT)" scripts/build-app.sh dev

release:
	BUILD_ROOT="$(BUILD_ROOT)" scripts/build-app.sh release

run-dev: dev
	open "$(BUILD_ROOT)/dev/GoldenPassport Dev.app"

clean:
	rm -rf "$(BUILD_ROOT)"

# Signed and notarized: make package SIGN_IDENTITY="Developer ID Application: …" NOTARIZE=1
package:
	BUILD_ROOT="$(BUILD_ROOT)" scripts/package.sh

beta:
	BUILD_ROOT="$(BUILD_ROOT)" scripts/package.sh beta
