#!/bin/sh
set -eu
REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# Test UserDefaults suites are named LimitFuel.<Kind>.<UUID>. removePersistentDomain
# empties them, but each process still leaves an empty plist when it exits.
list_test_defaults() {
    ls "$HOME/Library/Preferences" 2>/dev/null | grep -E \
        '^LimitFuel\.[A-Za-z]+(\.[A-Za-z]+)*\.[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}\.plist$' | sort || true
}
# Hooks return a short failure reason. Retain the exact failed-run transcript so
# a hook-only failure can be diagnosed; the child retains the same set -eu checks.
if [ "${1:-}" != "--inner" ]; then
    # A late rewrite can outlive a run's cleanup; settled test suites are removed here.
    find "$HOME/Library/Preferences" -maxdepth 1 -type f -mmin +2 -name 'LimitFuel.*.plist' 2>/dev/null \
        | sed 's|.*/||' | grep -E '^LimitFuel\.[A-Za-z]+(\.[A-Za-z]+)*\.[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}\.plist$' \
        | while IFS= read -r FILE; do rm -f "$HOME/Library/Preferences/$FILE"; done
    LOG=$(mktemp /private/tmp/limitfuel-checks.XXXXXX)
    BEFORE=$(mktemp /private/tmp/limitfuel-defaults.XXXXXX)
    list_test_defaults > "$BEFORE"
    if "$REPO/Tests/run.sh" --inner >"$LOG" 2>&1; then RESULT=0; else RESULT=$?; fi
    # Every test process has exited. cfprefsd rewrites a domain's plist once, about
    # two seconds after exit; wait it out, then remove only this run's suites.
    sleep 4
    list_test_defaults | comm -13 "$BEFORE" - | while IFS= read -r FILE; do
        rm -f "$HOME/Library/Preferences/$FILE"
    done
    rm -f "$BEFORE"
    cat "$LOG"
    if [ "$RESULT" -eq 0 ]; then
        rm "$LOG"
        exit 0
    fi
    echo "Failed test transcript: $LOG" >&2
    exit "$RESULT"
fi
BUILD=$(mktemp -d "/private/tmp/limitfuel-tests.XXXXXX")
trap 'rm -rf "$BUILD"' EXIT HUP INT TERM
SWIFTC=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc
SDK=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
python3 "$REPO/Tests/ReleaseWorkflowTests.py" --app-dir "$REPO/app"
python3 "$REPO/Tests/BoundedCommandTests.py"
# Compile the shared app once. Every suite still runs as a separate executable,
# with its original source copied byte-for-byte after one testable import.
"$SWIFTC" -D ACCEPTANCE_TESTS -sdk "$SDK" -module-cache-path "$BUILD/module-cache" \
  -enable-testing -whole-module-optimization -Onone -parse-as-library \
  -emit-library -emit-module -module-name LimitFuelAcceptance \
  -emit-module-path "$BUILD/LimitFuelAcceptance.swiftmodule" -lsqlite3 \
  -Xlinker -install_name -Xlinker @rpath/libLimitFuelAcceptance.dylib \
  "$REPO/app/AppDiagnostics.swift" "$REPO/app/LimitFuel.swift" "$REPO/app/ChromeCookies.swift" \
  "$REPO/app/CodexUsage.swift" "$REPO/app/CodexUsageView.swift" "$REPO/app/MenuBarStatus.swift" \
  "$REPO/app/PopupLayout.swift" "$REPO/app/MenuBarPreferences.swift" \
  -o "$BUILD/libLimitFuelAcceptance.dylib"

compile_acceptance() {
    TEST_SOURCE=$1
    TEST_OUTPUT=$2
    {
        printf '%s\n' '@testable import LimitFuelAcceptance'
        cat "$REPO/Tests/$TEST_SOURCE.swift"
    } > "$BUILD/$TEST_SOURCE.swift"
    "$SWIFTC" -D ACCEPTANCE_TESTS -sdk "$SDK" -module-cache-path "$BUILD/module-cache" \
      -parse-as-library -Onone -I "$BUILD" -L "$BUILD" -lLimitFuelAcceptance -lsqlite3 \
      -Xlinker -rpath -Xlinker "$BUILD" \
      "$BUILD/$TEST_SOURCE.swift" -o "$BUILD/$TEST_OUTPUT"
}

compile_acceptance "ChromeCookieReaderTests" "acceptance-tests"
CLAUDE_TEST_TMPDIR="$BUILD" "$BUILD/acceptance-tests"

compile_acceptance "UsageManagerTests" "lifecycle-tests"
CLAUDE_TEST_TMPDIR="$BUILD" "$BUILD/lifecycle-tests"
compile_acceptance "MenuBarStatusTests" "menubar-tests"
"$BUILD/menubar-tests"

compile_acceptance "CodexUsageTests" "codex-tests"
compile_acceptance "CodexMenuSelectionTests" "codex-menu-selection-tests"
"$BUILD/codex-menu-selection-tests"
"/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang" -isysroot "$SDK" "$REPO/Tests/CodexDescendantFixture.c" -o "$BUILD/codex-descendant-fixture"
python3 "$REPO/Tests/FixturePreparationTests.py" "$BUILD/codex-descendant-fixture"
# Bound loader preparation separately; all timed cleanup assertions stay unchanged.
python3 "$REPO/app/scripts/run_bounded.py" 30 "$BUILD/codex-descendant-fixture" --prepare
CLAUDE_TEST_TMPDIR="$BUILD" CLAUDE_CODEX_DESCENDANT_FIXTURE="$BUILD/codex-descendant-fixture" "$BUILD/codex-tests"

# Frozen spec-only desktop repair acceptance, using synthetic local fixtures.
for CASE in Chrome Codex Menu; do
    compile_acceptance "Desktop${CASE}Tests" "desktop-$CASE"
    CLAUDE_TEST_TMPDIR="$BUILD" LIMITFUEL_ASSET_DIR="$REPO/app/Assets" "$BUILD/desktop-$CASE"
done

# Frozen popup/provider display acceptance: deterministic geometry and PDF marks.
compile_acceptance "PopupAcceptanceTests" "popup-tests"
CLAUDE_TEST_TMPDIR="$BUILD" LIMITFUEL_ASSET_DIR="$REPO/app/Assets" "$BUILD/popup-tests"

compile_acceptance "MenuPreferencesAcceptance" "menu-preferences-tests"
"$BUILD/menu-preferences-tests"

compile_acceptance "MenuPreferencesIntegrationTests" "menu-preferences-integration-tests"
CLAUDE_TEST_TMPDIR="$BUILD" "$BUILD/menu-preferences-integration-tests"

compile_acceptance "MenuCountdownAcceptanceTests" "menu-countdown-tests"
LIMITFUEL_ASSET_DIR="$REPO/app/Assets" "$BUILD/menu-countdown-tests"

compile_acceptance "StaleBlurAcceptanceTests" "stale-blur-tests"
LIMITFUEL_ASSET_DIR="$REPO/app/Assets" "$BUILD/stale-blur-tests"

compile_acceptance "MenuRefreshStabilityTests" "menu-refresh-stability-tests"
CLAUDE_TEST_TMPDIR="$BUILD" "$BUILD/menu-refresh-stability-tests"

compile_acceptance "ProviderUpdateAgeTests" "provider-update-age-tests"
CLAUDE_TEST_TMPDIR="$BUILD" "$BUILD/provider-update-age-tests"

compile_acceptance "PercentageModeTests" "percentage-mode-tests"
CLAUDE_TEST_TMPDIR="$BUILD" "$BUILD/percentage-mode-tests"

compile_acceptance "ClaudePresentationAcceptanceTests" "claude-presentation-tests"
CLAUDE_TEST_TMPDIR="$BUILD" "$BUILD/claude-presentation-tests"

compile_acceptance "ClaudeWeeklyRuleTests" "claude-weekly-rule-tests"
CLAUDE_TEST_TMPDIR="$BUILD" "$BUILD/claude-weekly-rule-tests"

compile_acceptance "DiagnosticsTests" "diagnostics-tests"
"$BUILD/diagnostics-tests"

# Status alert expiry, meter mode, pickers, Codex account race, Claude
# connection state and legacy settings migration (spec-first, 2026-10-12).
for SUITE in StatusExpiryTests MeterModeTests CodexAccountRaceTests ClaudeSettingsConnectionTests LegacySettingsMigrationTests; do
    compile_acceptance "$SUITE" "$SUITE"
    CLAUDE_TEST_TMPDIR="$BUILD" LIMITFUEL_ASSET_DIR="$REPO/app/Assets" "$BUILD/$SUITE"
done

# Setup prepares the pinned SDK. Tests never download or send telemetry; missing
# dependencies fail instead of silently skipping the privacy checks.
SENTRY_DIR=$(python3 "$REPO/app/scripts/fetch_sentry.py" --offline)
"$SWIFTC" -D ACCEPTANCE_TESTS -sdk "$SDK" -module-cache-path "$BUILD/module-cache" \
  -F "$SENTRY_DIR" -framework Sentry -Xlinker -ObjC \
  "$REPO/app/AppDiagnostics.swift" "$REPO/app/SentryDiagnostics.swift" \
  "$REPO/Tests/SentryPrivacyTests.swift" -o "$BUILD/sentry-privacy-tests"
"$BUILD/sentry-privacy-tests"
