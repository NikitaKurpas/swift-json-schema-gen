#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

Scripts/swift-format.sh lint \
    --recursive \
    --parallel \
    --strict \
    Package.swift Plugins Sources Tests
