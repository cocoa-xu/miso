.PHONY: build test test-unit

INTEGRATION_TESTS = liveRestoreTicketsAuthenticatePreparedComponents|nativePolicyAuthenticatesPreparedMaterial|pinnedCLTPackagesPassNativePreparation|nativeTarReadsRetainedRunnerRelease

build:
	swift build -c release --disable-automatic-resolution
	codesign --force --sign - --entitlements Resources/miso.entitlements "$$(swift build -c release --disable-automatic-resolution --show-bin-path)/miso"

test:
	swift test

test-unit:
	swift test --disable-automatic-resolution --skip '$(INTEGRATION_TESTS)'
