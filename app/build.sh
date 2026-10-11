#!/bin/bash
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR"

# Build script for LimitFuel

echo "Building LimitFuel..."

LOCAL_BUILD=false
case "${1:-}" in
    --local) LOCAL_BUILD=true ;;
    "") ;;
    *) echo "Usage: ./build.sh [--local]" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then echo "Usage: ./build.sh [--local]" >&2; exit 2; fi
if ! mkdir .release-lock 2>/dev/null; then
    echo "Another build/release owns .release-lock" >&2
    exit 1
fi
ACTIVE_COMMAND=""
cleanup() {
    if [ -n "$ACTIVE_COMMAND" ]; then
        kill -TERM "$ACTIVE_COMMAND" 2>/dev/null || true
        wait "$ACTIVE_COMMAND" 2>/dev/null || true
    fi
    rmdir .release-lock
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
run_bounded() {
    python3 scripts/run_bounded.py "$@" &
    ACTIVE_COMMAND=$!
    if wait "$ACTIVE_COMMAND"; then result=0; else result=$?; fi
    ACTIVE_COMMAND=""
    return "$result"
}

DEVELOPER_ID=${DEVELOPER_ID-Developer ID Application: Innolope LLC (MQD26CY5MA)}
if ! $LOCAL_BUILD; then
    python3 scripts/build_info.py --check-identity "$DEVELOPER_ID"
fi

# Create fresh build directory (delete any stale build to avoid accumulated xattrs
# from prior signs, which can cause "resource fork / detritus" errors on codesign).
rm -rf build
mkdir -p build

# Official static SDK, verified against pinned release checksums. Keep downloads
# outside build/ so local rebuilds can work from the verified cache.
run_bounded 300 python3 scripts/fetch_sentry.py > build/sentry-framework-path
SENTRY_FRAMEWORK_DIR=$(cat build/sentry-framework-path)

# Create app bundle structure first
APP_NAME="LimitFuel.app"
APP_PATH="build/$APP_NAME"

mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

# Copy Info.plist
cp Info.plist "$APP_PATH/Contents/"
cp Diagnostics.plist "$APP_PATH/Contents/Resources/"
cp .dependencies/Sentry-9.30.1-LICENSE.md "$APP_PATH/Contents/Resources/Sentry-LICENSE.md"
mkdir -p "$APP_PATH/Contents/Resources/SentryPrivacy.bundle"
cp SentryPrivacy-Info.plist "$APP_PATH/Contents/Resources/SentryPrivacy.bundle/Info.plist"
cp "$SENTRY_FRAMEWORK_DIR/Sentry.framework/Resources/PrivacyInfo.xcprivacy" \
    "$APP_PATH/Contents/Resources/SentryPrivacy.bundle/"
cp Assets/*.pdf "$APP_PATH/Contents/Resources/"
python3 scripts/build_info.py "$APP_PATH"

# Create icon if it doesn't exist
if [ ! -f "LimitFuel.icns" ]; then
    echo "Creating app icon..."
    ./make_app_icon.sh >/dev/null 2>&1
fi

# Copy icon to Resources
if [ -f "LimitFuel.icns" ]; then
    cp LimitFuel.icns "$APP_PATH/Contents/Resources/"
    # Update Info.plist to reference icon
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string LimitFuel" "$APP_PATH/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile LimitFuel" "$APP_PATH/Contents/Info.plist"
fi

# Compile the Swift app for arm64
run_bounded 600 swiftc -parse-as-library -o "$APP_PATH/Contents/MacOS/LimitFuel_arm64" \
    -module-cache-path build/ModuleCache \
    LimitFuel.swift ChromeCookies.swift CodexUsage.swift CodexUsageView.swift MenuBarStatus.swift MenuBarPreferences.swift PopupLayout.swift AppDiagnostics.swift SentryDiagnostics.swift \
    -F "$SENTRY_FRAMEWORK_DIR" -framework Sentry -Xlinker -ObjC \
    -lsqlite3 -framework Security \
    -framework SwiftUI \
    -framework AppKit \
    -framework WebKit \
    -target arm64-apple-macos12.0

# Compile for x86_64 (Intel)
run_bounded 600 swiftc -parse-as-library -o "$APP_PATH/Contents/MacOS/LimitFuel_x86_64" \
    -module-cache-path build/ModuleCache \
    LimitFuel.swift ChromeCookies.swift CodexUsage.swift CodexUsageView.swift MenuBarStatus.swift MenuBarPreferences.swift PopupLayout.swift AppDiagnostics.swift SentryDiagnostics.swift \
    -F "$SENTRY_FRAMEWORK_DIR" -framework Sentry -Xlinker -ObjC \
    -lsqlite3 -framework Security \
    -framework SwiftUI \
    -framework AppKit \
    -framework WebKit \
    -target x86_64-apple-macos12.0

# Create universal binary
run_bounded 120 lipo -create -output "$APP_PATH/Contents/MacOS/LimitFuel" \
    "$APP_PATH/Contents/MacOS/LimitFuel_arm64" \
    "$APP_PATH/Contents/MacOS/LimitFuel_x86_64"

# Clean up individual arch binaries
rm "$APP_PATH/Contents/MacOS/LimitFuel_arm64"
rm "$APP_PATH/Contents/MacOS/LimitFuel_x86_64"

# Create PkgInfo file
echo -n "APPL????" > "$APP_PATH/Contents/PkgInfo"

# Set proper permissions first
chmod 755 "$APP_PATH/Contents/MacOS/LimitFuel"

# Clean any "detritus" that codesign rejects: extended attributes, ._files, .DS_Store
run_bounded 120 xattr -cr "$APP_PATH"
find "$APP_PATH" -name '._*' -delete 2>/dev/null
find "$APP_PATH" -name '.DS_Store' -delete 2>/dev/null
run_bounded 120 dot_clean "$APP_PATH" 2>/dev/null
python3 scripts/build_info.py "$APP_PATH" --verify

# Explicit local builds use an ad-hoc signature and do not launch automatically.
# Distribution builds require Developer ID and never fall back to ad-hoc.
if $LOCAL_BUILD; then
    run_bounded 120 codesign --force --deep --sign - "$APP_PATH"
    run_bounded 120 codesign --verify --deep --strict "$APP_PATH"
    echo "Local universal app built: $APP_PATH (ad-hoc signed, not notarized)"
    exit 0
fi

# Sign with Developer ID certificate. NEVER silently fall back to ad-hoc — that
# fails notarization later. If real signing fails, error out loudly.
if run_bounded 120 codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP_PATH"; then
    echo "✅ App signed with Developer ID"
    if run_bounded 120 codesign --verify --deep --strict "$APP_PATH"; then
        echo "✅ Signature verified"
    else
        echo "❌ Signature verification failed — fix before shipping" >&2
        exit 1
    fi
else
    echo "❌ Developer ID signing failed. NOT falling back to ad-hoc (would break notarization)." >&2
    echo "   Fix the cause above (often: stale xattrs / ._files / cert not in keychain) and re-run." >&2
    exit 1
fi

echo "Build successful!"
echo "App bundle created at: $APP_PATH"
echo "Run ./create_dmg.sh explicitly to notarize and package a release."
