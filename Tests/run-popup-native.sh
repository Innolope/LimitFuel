#!/bin/sh
set -eu
TEST_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_OUTPUT=${CLAUDE_TEST_TMPDIR:-$(mktemp -d)}
mkdir -p "$TEST_OUTPUT"
TEST_SWIFTC=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc
TEST_SDK=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
"$TEST_SWIFTC" -D ACCEPTANCE_TESTS -sdk "$TEST_SDK" -module-cache-path "$TEST_OUTPUT/module-cache" -lsqlite3 "${POPUP_SOURCE_ROOT:-$TEST_ROOT/app}/AppDiagnostics.swift" "${POPUP_SOURCE_ROOT:-$TEST_ROOT/app}/LimitFuel.swift" "${POPUP_SOURCE_ROOT:-$TEST_ROOT/app}/ChromeCookies.swift" "${POPUP_SOURCE_ROOT:-$TEST_ROOT/app}/CodexUsage.swift" "${POPUP_SOURCE_ROOT:-$TEST_ROOT/app}/CodexUsageView.swift" "${POPUP_SOURCE_ROOT:-$TEST_ROOT/app}/MenuBarStatus.swift" "${POPUP_SOURCE_ROOT:-$TEST_ROOT/app}/PopupLayout.swift" "${POPUP_SOURCE_ROOT:-$TEST_ROOT/app}/MenuBarPreferences.swift" "${POPUP_TEST_SOURCE:-$TEST_ROOT/Tests/PopupNativeTests.swift}" -o "$TEST_OUTPUT/popup-native-acceptance"
if [ "${POPUP_COMPILE_ONLY:-0}" = 1 ]; then exit 0; fi
LIMITFUEL_ASSET_DIR="$TEST_ROOT/app/Assets" "$TEST_OUTPUT/popup-native-acceptance"
