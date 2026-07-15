#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE_CACHE="$ROOT/.build/ModuleCache"
mkdir -p "$MODULE_CACHE"

export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"

# This machine currently has a 6.3.3 compiler paired with a mismatched 26.5 SDK.
# The bundled 15.4 SDK is compatible and still builds a macOS 14 deployment target.
FALLBACK_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
if [[ -z "${SDKROOT:-}" && -d "$FALLBACK_SDK" ]]; then
    export SDKROOT="$FALLBACK_SDK"
fi
