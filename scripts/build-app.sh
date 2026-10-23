#!/usr/bin/env bash
# Build VoiceType and stage a self-contained macOS app bundle in build/.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/build/VoiceType.app"

cd "$ROOT_DIR"
# Keep compiler module-cache artifacts inside the ignored build directory.
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/clang-module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$CLANG_MODULE_CACHE_PATH}"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
# The package has no plugins or external dependencies; avoid the deprecated macOS sandbox-exec path.
swift build --disable-sandbox -c release --jobs 2 --product VoiceType

BIN_DIR="$(swift build --disable-sandbox -c release --show-bin-path)"
EXECUTABLE="$BIN_DIR/VoiceType"

if [[ ! -f "$EXECUTABLE" ]]; then
    echo "error: expected executable was not produced: $EXECUTABLE" >&2
    exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/VoiceType"
chmod 755 "$APP_BUNDLE/Contents/MacOS/VoiceType"
if command -v codesign >/dev/null 2>&1; then
    BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist")"
    if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
        # A real identity (e.g. "Apple Development: …") gives the most stable TCC permissions.
        codesign --force --sign "$CODESIGN_IDENTITY" --timestamp=none "$APP_BUNDLE"
    else
        # Local ad-hoc build. An identifier-based designated requirement lets macOS privacy grants
        # (Microphone / Speech / Accessibility) survive rebuilds instead of binding to one cdhash.
        # Trade-off: any ad-hoc binary claiming this bundle ID would match; development use only.
        codesign --force --sign - --timestamp=none --identifier "$BUNDLE_ID" \
            -r="designated => identifier \"$BUNDLE_ID\"" "$APP_BUNDLE"
    fi
fi

plutil -lint "$APP_BUNDLE/Contents/Info.plist"

if [[ ! -d "$APP_BUNDLE" || ! -f "$APP_BUNDLE/Contents/Info.plist" || ! -x "$APP_BUNDLE/Contents/MacOS/VoiceType" ]]; then
    echo "error: app bundle validation failed: $APP_BUNDLE" >&2
    exit 1
fi

if command -v codesign >/dev/null 2>&1; then
    codesign --verify --deep --strict "$APP_BUNDLE"
fi

echo "Built $APP_BUNDLE"
