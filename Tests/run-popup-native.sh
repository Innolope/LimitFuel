#!/bin/sh
set -eu
TEST_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_OUTPUT=${CLAUDE_TEST_TMPDIR:-$(mktemp -d)}
mkdir -p "$TEST_OUTPUT"
TEST_SWIFTC=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc
TEST_SDK=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
"$TEST_SWIFTC" -D ACCEPTANCE_TESTS -sdk "$TEST_SDK" -module-cache-path "$TEST_OUTPUT/module-cache" -lsqlite3 "${POPUP_SOURCE_ROOT:-$TEST_ROOT/app}/AppDiagnostics.swift" "${POPUP_SOURCE_ROOT:-$TEST_ROOT/app}/LimitFuel.swift" "${POPUP_SOURCE_ROOT:-$TEST_ROOT/app}/ChromeCookies.swift" "${POPUP_SOURCE_ROOT:-$TEST_ROOT/app}/CodexUsage.swift" "${POPUP_SOURCE_ROOT:-$TEST_ROOT/app}/CodexUsageView.swift" "${POPUP_SOURCE_ROOT:-$TEST_ROOT/app}/MenuBarStatus.swift" "${POPUP_SOURCE_ROOT:-$TEST_ROOT/app}/PopupLayout.swift" "${POPUP_SOURCE_ROOT:-$TEST_ROOT/app}/MenuBarPreferences.swift" "${POPUP_TEST_SOURCE:-$TEST_ROOT/Tests/PopupNativeTests.swift}" -o "$TEST_OUTPUT/popup-native-acceptance"
if [ "${POPUP_COMPILE_ONLY:-0}" = 1 ]; then exit 0; fi
# The verifier's LimitFuel.PopupVerifier.<UUID> suite leaves an empty plist on exit;
# a late rewrite can outlive this script's cleanup, so settled ones go first.
find "$HOME/Library/Preferences" -maxdepth 1 -type f -mmin +2 -name 'LimitFuel.PopupVerifier.*.plist' 2>/dev/null \
    | sed 's|.*/||' | grep -E '^LimitFuel\.PopupVerifier\.[0-9A-F-]{36}\.plist$' \
    | while IFS= read -r FILE; do rm -f "$HOME/Library/Preferences/$FILE"; done
PREFS_BEFORE=$(ls "$HOME/Library/Preferences")
STATUS=0
LIMITFUEL_ASSET_DIR="$TEST_ROOT/app/Assets" "$TEST_OUTPUT/popup-native-acceptance" || STATUS=$?
sleep 4 # cfprefsd rewrites the plist about two seconds after the process exits
ls "$HOME/Library/Preferences" | grep -E '^LimitFuel\.PopupVerifier\.[0-9A-F-]{36}\.plist$' | while IFS= read -r FILE; do
    printf '%s\n' "$PREFS_BEFORE" | grep -qxF "$FILE" || rm -f "$HOME/Library/Preferences/$FILE"
done
exit "$STATUS"
