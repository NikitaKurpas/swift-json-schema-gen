#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: Scripts/package-release.sh <version> [output-directory]" >&2
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
    usage
    exit 64
fi

version="${1#v}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ && "$version" != "dev" ]]; then
    echo "error: version must be a semantic version or 'dev'" >&2
    exit 64
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_directory="${2:-$repo_root/dist}"

case "$(uname -s)" in
    Darwin) platform="macos" ;;
    Linux) platform="linux" ;;
    *)
        echo "error: release archives are supported on macOS and Linux" >&2
        exit 69
        ;;
esac

case "$(uname -m)" in
    arm64 | aarch64) architecture="arm64" ;;
    x86_64 | amd64) architecture="x86_64" ;;
    *)
        echo "error: unsupported release architecture: $(uname -m)" >&2
        exit 69
        ;;
esac

asset_name="SwiftJSONSchemaGen-${version}-${platform}-${architecture}"
stage_parent="$(mktemp -d "${TMPDIR:-/tmp}/swift-json-schema-gen-release.XXXXXX")"
trap 'rm -rf "$stage_parent"' EXIT
stage="$stage_parent/$asset_name"
mkdir -p "$stage"

cd "$repo_root"
if [[ "$platform" == "linux" ]]; then
    swift build -q --configuration release --static-swift-stdlib --product SwiftJSONSchemaGen
else
    swift build -q --configuration release --product SwiftJSONSchemaGen
fi
binary_directory="$(swift build -q --configuration release --show-bin-path)"

install -m 0755 "$binary_directory/SwiftJSONSchemaGen" "$stage/SwiftJSONSchemaGen"
if [[ "$version" != "dev" ]]; then
    executable_version="$("$stage/SwiftJSONSchemaGen" --version)"
    if [[ "$executable_version" != "$version" ]]; then
        echo "error: executable reports $executable_version, expected $version" >&2
        exit 70
    fi
fi

resource_bundle=""
while IFS= read -r candidate; do
    if [[ -n "$resource_bundle" ]]; then
        echo "error: found more than one SwiftJSONSchemaGen resource bundle" >&2
        exit 70
    fi
    resource_bundle="$candidate"
done < <(find "$binary_directory" -maxdepth 1 -type d \
    \( -name 'SwiftJSONSchemaGen_JSONSchemaGeneration.bundle' \
    -o -name 'SwiftJSONSchemaGen_JSONSchemaGeneration.resources' \) -print)

if [[ -z "$resource_bundle" ]]; then
    echo "error: SwiftJSONSchemaGen resource bundle was not produced" >&2
    exit 70
fi
cp -R "$resource_bundle" "$stage/"

for document in LICENSE NOTICE THIRD-PARTY.md README.md ARCHITECTURE.md CONTRIBUTING.md CHANGELOG.md; do
    if [[ ! -f "$repo_root/$document" ]]; then
        echo "error: required release document is missing: $document" >&2
        exit 66
    fi
    cp "$repo_root/$document" "$stage/$document"
done
if [[ ! -f "$repo_root/Docs/logo.svg" || ! -f "$repo_root/Docs/SchemaSupport.md" ]]; then
    echo "error: required release documentation is missing from Docs" >&2
    exit 66
fi
mkdir -p "$stage/Docs"
cp "$repo_root/Docs/logo.svg" "$repo_root/Docs/SchemaSupport.md" "$stage/Docs/"

license_directory="$stage/ThirdPartyLicenses"
mkdir -p "$license_directory"
cp "$repo_root/Package.resolved" "$license_directory/Package.resolved"
found_dependencies=false
for checkout in "$repo_root/.build/checkouts"/*; do
    [[ -d "$checkout" ]] || continue
    found_dependencies=true
    dependency="$(basename "$checkout")"
    found_license=false
    while IFS= read -r license; do
        found_license=true
        cp "$license" "$license_directory/${dependency}-$(basename "$license")"
    done < <(find "$checkout" -maxdepth 1 -type f \
        \( -iname 'LICENSE' -o -iname 'LICENSE.*' -o -iname 'NOTICE' -o -iname 'NOTICE.*' \) \
        -print)
    if [[ "$found_license" != true ]]; then
        echo "error: dependency checkout has no root license file: $dependency" >&2
        exit 70
    fi
done
if [[ "$found_dependencies" != true ]]; then
    echo "error: no resolved dependency checkouts were found" >&2
    exit 70
fi

mkdir -p "$output_directory"
archive="$output_directory/$asset_name.tar.gz"
tar -C "$stage_parent" -czf "$archive" "$asset_name"

if command -v sha256sum >/dev/null 2>&1; then
    (cd "$output_directory" && sha256sum "$(basename "$archive")") > "$archive.sha256"
else
    (cd "$output_directory" && shasum -a 256 "$(basename "$archive")") > "$archive.sha256"
fi

echo "$archive"
