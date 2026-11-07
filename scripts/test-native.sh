#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_directory=$(mktemp -d "${TMPDIR:-/tmp}/ble-background-tests.XXXXXX")
trap 'rm -rf "$test_directory"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-parameter \
    -framework Foundation -Isrc/ios src/ios/BLEBackgroundProtocol.m test/protocol-tests.m \
    -o "$test_directory/protocol-tests"
"$test_directory/protocol-tests"
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-parameter \
    -framework Foundation -Isrc/ios src/ios/BLEBackgroundReporting.m test/reporting-tests.m \
    -o "$test_directory/reporting-tests"
"$test_directory/reporting-tests"
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-parameter \
    -framework Foundation -framework Security -Isrc/ios src/ios/BLEBackgroundStore.m test/store-tests.m \
    -o "$test_directory/store-tests"
"$test_directory/store-tests"
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-parameter \
    -Wno-incompatible-pointer-types -Wno-objc-protocol-method-implementation \
    -framework Foundation -framework CoreBluetooth -framework Security \
    -Itest/ios-mocks -Isrc/ios test/ios-mocks/runtime.m src/ios/BLEBackgroundPlugin.m \
    src/ios/BLEBackgroundProtocol.m src/ios/BLEBackgroundReporting.m src/ios/BLEBackgroundStore.m \
    test/restoration-tests.m -o "$test_directory/restoration-tests"
"$test_directory/restoration-tests"
