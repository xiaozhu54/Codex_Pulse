#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/Scripts/swift-env.sh"

swift run \
    --disable-sandbox \
    --scratch-path "$ROOT/.build" \
    CodexPulseBehaviorTests
