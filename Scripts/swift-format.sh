#!/usr/bin/env bash
set -euo pipefail

if command -v swift-format >/dev/null 2>&1; then
    exec swift-format "$@"
fi
if command -v xcrun >/dev/null 2>&1; then
    exec xcrun swift-format "$@"
fi

echo "error: swift-format was not found in PATH or the active Xcode toolchain" >&2
exit 69
