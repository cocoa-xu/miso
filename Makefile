.PHONY: build test

build:
	swift build -c release
	codesign --force --sign - --entitlements Resources/miso.entitlements "$$(swift build -c release --show-bin-path)/miso"

test:
	swift test
