#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: Scripts/verify-release-archive.sh <archive.tar.gz>" >&2
    exit 64
fi

archive="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
checksum="$archive.sha256"
if [[ ! -f "$archive" || ! -f "$checksum" ]]; then
    echo "error: archive and adjacent .sha256 file are required" >&2
    exit 66
fi

if command -v sha256sum >/dev/null 2>&1; then
    (cd "$(dirname "$archive")" && sha256sum --check "$(basename "$checksum")")
else
    (cd "$(dirname "$archive")" && shasum -a 256 --check "$(basename "$checksum")")
fi

verification_directory="$(mktemp -d "${TMPDIR:-/tmp}/swift-json-schema-gen-verify.XXXXXX")"
trap 'rm -rf "$verification_directory"' EXIT
tar -C "$verification_directory" -xzf "$archive"

package_directory="$(find "$verification_directory" -mindepth 1 -maxdepth 1 -type d -print -quit)"
executable="$package_directory/SwiftJSONSchemaGen"
if [[ ! -x "$executable" ]]; then
    echo "error: archive does not contain an executable SwiftJSONSchemaGen" >&2
    exit 70
fi

for document in LICENSE NOTICE THIRD-PARTY.md README.md ARCHITECTURE.md CONTRIBUTING.md \
    CHANGELOG.md Docs/logo.svg Docs/SchemaSupport.md ThirdPartyLicenses/Package.resolved; do
    if [[ ! -f "$package_directory/$document" ]]; then
        echo "error: archive is missing $document" >&2
        exit 70
    fi
done

resource_bundle="$(find "$package_directory" -mindepth 1 -maxdepth 1 -type d \
    \( -name 'SwiftJSONSchemaGen_JSONSchemaGeneration.bundle' \
    -o -name 'SwiftJSONSchemaGen_JSONSchemaGeneration.resources' \) -print -quit)"
if [[ -z "$resource_bundle" ]]; then
    echo "error: archive is missing the SwiftJSONSchemaGen resource bundle" >&2
    exit 70
fi

dependency_license="$(find "$package_directory/ThirdPartyLicenses" -maxdepth 1 -type f \
    -iname '*-LICENSE*' -print -quit)"
if [[ -z "$dependency_license" ]]; then
    echo "error: archive is missing dependency license files" >&2
    exit 70
fi

schema="$verification_directory/smoke.schema.json"
generated="$verification_directory/Smoke.generated.swift"
printf '%s\n' \
    '{' \
    '  "$schema": "https://json-schema.org/draft/2020-12/schema",' \
    '  "title": "ReleaseSmoke",' \
    '  "type": "object",' \
    '  "properties": { "name": { "type": "string" } },' \
    '  "required": ["name"]' \
    '}' > "$schema"

"$executable" --output "$generated" "$schema"
test -s "$generated"

echo "Verified $(basename "$archive")"
