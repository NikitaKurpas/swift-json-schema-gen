#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="${1:-dev}"
output_directory="$(mktemp -d "${TMPDIR:-/tmp}/swift-json-schema-gen-test-release.XXXXXX")"
trap 'rm -rf "$output_directory"' EXIT

"$repo_root/Scripts/package-release.sh" "$version" "$output_directory"
archive="$(find "$output_directory" -maxdepth 1 -type f -name '*.tar.gz' -print -quit)"
if [[ -z "$archive" ]]; then
    echo "error: release packaging did not produce an archive" >&2
    exit 70
fi

binary_directory="$(
    cd "$repo_root"
    swift build -q --configuration release --show-bin-path
)"
resource_bundle="$(find "$binary_directory" -maxdepth 1 -type d \
    \( -name 'SwiftJSONSchemaGen_JSONSchemaGeneration.bundle' \
    -o -name 'SwiftJSONSchemaGen_JSONSchemaGeneration.resources' \) -print -quit)"
hidden_bundle="$output_directory/original-resource-bundle"

restore_bundle() {
    if [[ -e "$hidden_bundle" ]]; then
        mv "$hidden_bundle" "$resource_bundle"
    fi
    rm -rf "$output_directory"
}
trap restore_bundle EXIT

mv "$resource_bundle" "$hidden_bundle"
"$repo_root/Scripts/verify-release-archive.sh" "$archive"
