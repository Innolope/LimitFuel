#!/bin/sh
set -eu
REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# Hooks return a short failure reason. Retain the exact failed-run transcript so
# a hook-only failure can be diagnosed; the child retains the same set -eu checks.
if [ "${1:-}" != "--inner" ]; then
    LOG=$(mktemp /private/tmp/limitfuel-checks.XXXXXX)
    if "$REPO/Tests/run.sh" --inner >"$LOG" 2>&1; then
        cat "$LOG"
        rm "$LOG"
        exit 0
    else
        RESULT=$?
        cat "$LOG"
        echo "Failed test transcript: $LOG" >&2
        exit "$RESULT"
    fi
fi
BUILD=$(mktemp -d "/private/tmp/limitfuel-tests.XXXXXX")
trap 'rm -rf "$BUILD"' EXIT HUP INT TERM
SWIFTC=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc
SDK=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
python3 "$REPO/Tests/ReleaseWorkflowTests.py" --app-dir "$REPO/app"
python3 "$REPO/Tests/BoundedCommandTests.py"
"$SWIFTC" -sdk "$SDK" -module-cache-path "$BUILD/module-cache" -lsqlite3 \
  "$REPO/app/ChromeCookies.swift" "$REPO/Tests/ChromeCookieReaderTests.swift" -o "$BUILD/acceptance-tests"
CLAUDE_TEST_TMPDIR="$BUILD" "$BUILD/acceptance-tests"

"$SWIFTC" -D ACCEPTANCE_TESTS -sdk "$SDK" -module-cache-path "$BUILD/module-cache" -lsqlite3 \
  "$REPO/app/LimitFuel.swift" "$REPO/app/ChromeCookies.swift" "$REPO/app/CodexUsage.swift" "$REPO/app/CodexUsageView.swift" "$REPO/app/MenuBarStatus.swift" "$REPO/Tests/UsageManagerTests.swift" -o "$BUILD/lifecycle-tests"
CLAUDE_TEST_TMPDIR="$BUILD" "$BUILD/lifecycle-tests"
"$SWIFTC" -sdk "$SDK" -module-cache-path "$BUILD/module-cache" "$REPO/app/MenuBarStatus.swift" "$REPO/Tests/MenuBarStatusTests.swift" -o "$BUILD/menubar-tests"
"$BUILD/menubar-tests"

"$SWIFTC" -sdk "$SDK" -module-cache-path "$BUILD/module-cache" "$REPO/app/CodexUsage.swift" "$REPO/Tests/CodexUsageTests.swift" -o "$BUILD/codex-tests"
"/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang" -isysroot "$SDK" "$REPO/Tests/CodexDescendantFixture.c" -o "$BUILD/codex-descendant-fixture"
CLAUDE_TEST_TMPDIR="$BUILD" CLAUDE_CODEX_DESCENDANT_FIXTURE="$BUILD/codex-descendant-fixture" "$BUILD/codex-tests"
