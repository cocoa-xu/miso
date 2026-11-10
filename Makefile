.PHONY: build test test-unit

INTEGRATION_TESTS = liveRestoreTicketsAuthenticatePreparedComponents|nativePolicyAuthenticatesPreparedMaterial|pinnedCLTPackagesPassNativePreparation|nativeTarReadsRetainedRunnerRelease|nativeDeveloperDisksInstallAndRefreshFromSignedXcode|nativeImageMountLifecycle|nativeSpotlightVolumePolicy|nativeSessionSchemaPreservesScreenSharingThroughBaseSeeding
MEMORY_TESTS = streamingHashHasBoundedMemory|streamingCryptexHashHasBoundedMemory
SWIFT_TEST_FLAGS = --build-system native --disable-automatic-resolution --disable-xctest --enable-swift-testing

build:
	swift build -c release --disable-automatic-resolution
	codesign --force --sign - --entitlements Resources/miso.entitlements "$$(swift build -c release --disable-automatic-resolution --show-bin-path)/miso"

test:
	swift test $(SWIFT_TEST_FLAGS)

test-unit:
	swift test $(SWIFT_TEST_FLAGS) --skip '$(INTEGRATION_TESTS)|$(MEMORY_TESTS)'
	swift test $(SWIFT_TEST_FLAGS) --skip-build --filter '$(MEMORY_TESTS)' --no-parallel
