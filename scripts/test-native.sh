#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_directory=$(mktemp -d "${TMPDIR:-/tmp}/ble-background-tests.XXXXXX")
trap 'rm -rf "$test_directory"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-parameter \
    -framework Foundation -Isrc/ios src/ios/BLEBackgroundProtocol.m test/protocol-tests.m \
    -o "$test_directory/protocol-tests"
"$test_directory/protocol-tests"
