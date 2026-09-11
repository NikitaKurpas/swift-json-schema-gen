#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_fixture="$repo_root/Tests/PluginFixtures/Basic"
fixture="$(mktemp -d "$repo_root/Tests/PluginFixtures/.plugin-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

cp "$source_fixture/Package.swift" "$source_fixture/Package.resolved" "$fixture/"
cp -R "$source_fixture/Sources" "$fixture/"

swift build -q --package-path "$fixture"

generated="$(find "$fixture/.build/plugins/outputs" -type f -name 'SwiftJSONSchemaGen.generated.swift' -print -quit)"
test -n "$generated"
grep -q 'public struct Person' "$generated"
grep -q 'nicknameV1' "$generated"

initial_checksum="$(cksum "$generated")"
unchanged_build_start="$fixture/.unchanged-build-start"
touch "$unchanged_build_start"
swift build -q --package-path "$fixture"
test "$initial_checksum" = "$(cksum "$generated")"
test ! "$generated" -nt "$unchanged_build_start"

schema="$fixture/Sources/Fixture/Schemas/person.schema.json"
sed 's/nicknameV1/nicknameV2/g' "$schema" > "$schema.updated"
mv "$schema.updated" "$schema"

swift build -q --package-path "$fixture"
test "$initial_checksum" != "$(cksum "$generated")"
grep -q 'nicknameV2' "$generated"
if grep -q 'nicknameV1' "$generated"; then
    echo "plugin output was not regenerated after its schema input changed" >&2
    exit 1
fi
