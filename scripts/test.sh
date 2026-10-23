#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/.work/voicetype-build"
mkdir -p "$WORK"/{cache,module-cache,config,security}
export CLANG_MODULE_CACHE_PATH="$WORK/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$WORK/module-cache"
cd "$ROOT"
OPTIONS=(--disable-sandbox --jobs 2 --scratch-path "$WORK/scratch" --cache-path "$WORK/cache" --config-path "$WORK/config" --security-path "$WORK/security")
SWIFT_BIN="$(dirname "$(xcrun --find swiftc)")"
TESTING_PLUGIN="$SWIFT_BIN/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ -f "$TESTING_PLUGIN" ]] && swift test --help | grep -q -- '--enable-swift-testing'; then
    # CLT 6.4 has Testing but doesn't automatically resolve its macro plugin.
    OPTIONS+=(--disable-xctest --enable-swift-testing -Xswiftc -load-plugin-library -Xswiftc "$TESTING_PLUGIN")
fi
swift test "${OPTIONS[@]}" "$@"
