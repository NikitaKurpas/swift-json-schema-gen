<p align="center">
  <img src="Docs/logo.svg" alt="SwiftJSONSchemaGen — JSON Schema to Swift Codable" width="840" />
</p>

# SwiftJSONSchemaGen

Turn JSON Schema into Swift models you can read, construct, and use with
`JSONEncoder` and `JSONDecoder`. Generate a file from the command line, call the
Swift library, or let SwiftPM generate models during your build.

Generated models depend on Foundation only. Import `JSONSchemaGeneration` when
embedding the generator; the package and command-line tool are named
`SwiftJSONSchemaGen`.

**Requirements:** Swift 6.3+, macOS 15+ or Linux. The generator's toolchain requirements
are separate from the platforms supported by its generated Foundation/Codable code.

## Main features

- **Codable models:** objects, arrays, primitive types, scalar enums, and constants,
  with original JSON key spelling preserved.
- **Presence and nullability:** required keys must exist, and non-nullable fields
  reject explicit null even when the field is optional.
- **Composed and recursive types:** `oneOf` and `anyOf` unions, object `allOf`
  intersections, recursive objects, and recursive unions.
- **Reusable schemas:** offline `$ref` resolution across supplied documents,
  `$id` identities, anchors, JSON Pointer, and namespaced `$defs` / `definitions`.
- **Flexible JSON:** typed or arbitrary additional properties and a generated
  `AnyValue` for unconstrained JSON, with no third-party runtime dependency.
- **Build integration:** direct CLI arguments, JSON configuration, an in-memory
  Swift API, and a SwiftPM build tool plugin. Optional `Sendable` generation supports
  concurrency-aware consumers.
- **Reproducible workflows:** deterministic output, unchanged-file preservation,
  `--check` for stale generated files, and human-readable or JSON diagnostics.

Draft 7, 2019-09, and 2020-12 are recognized. Some shapes have restrictions and some
validation keywords are not enforced; see the [support matrix](Docs/SchemaSupport.md).

For example, these schema fragments select the following model shapes:

| Schema | Swift model shape |
| --- | --- |
| `{"type":"array","items":{"type":"string"}}` | `[String]` |
| `{"type":"string","enum":["draft","published"]}` | String-backed enum |
| `{"type":["string","null"]}` | Nullable string |
| `{"oneOf":[{"type":"string"},{"type":"integer"}]}` | Codable union with exclusive branch matching |
| `{"type":"object","additionalProperties":{"type":"integer"}}` | Object retaining integer-valued extra fields |
| `true` | Generated `AnyValue` |

## Generate your first model

Try the checked-in example from a checkout of this standalone repository:

```sh
swift run -q SwiftJSONSchemaGen --config Examples/swift-json-schema-gen.json
```

It writes `Examples/Generated/SchemaTypes.swift`. To use your own schema:

```sh
swift run -q SwiftJSONSchemaGen --output Models.swift person.schema.json
```

For this `person.schema.json`:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "Person",
  "type": "object",
  "properties": {
    "id": { "type": "integer" },
    "name": { "type": "string" }
  },
  "required": ["id", "name"],
  "additionalProperties": false
}
```

Use the generated model in your application:

```swift
import Foundation

let person = Person(id: 42, name: "Ada")
let data = try JSONEncoder().encode(person)
let decoded = try JSONDecoder().decode(Person.self, from: data)
print(decoded.name)
```

Build an optimized executable with `swift build -q -c release`. Keep its resource
bundle beside the executable when installing it; the release archives contain the
required files together. `SwiftJSONSchemaGen --help` lists the command options.

If you downloaded a binary release, extract the archive and run its executable:

```sh
./SwiftJSONSchemaGen --output Models.swift person.schema.json
```

Add the extracted directory to your `PATH` to run it from elsewhere. Keep the resource
bundle alongside the executable; copying only the executable is insufficient. Use the
archive that matches your operating system and architecture.

## Use a configuration file

Commit generation settings alongside your schema:

```json
{
  "schemas": ["Schemas/person.schema.json"],
  "output": "Sources/Models/Generated.swift",
  "sendable": true,
  "warningsAsErrors": true
}
```

```sh
swift run -q SwiftJSONSchemaGen --config swift-json-schema-gen.json
```

Paths in the configuration are relative to that file's directory, so the command
works from another working directory. Explicit command-line values override the
configuration. Positional schema paths replace the configured input list. Command-line
paths are relative to the working directory.

```sh
swift run -q SwiftJSONSchemaGen --config swift-json-schema-gen.json \
  --output /tmp/Models.swift --no-sendable
```

| CLI | Config key | Default |
| --- | --- | --- |
| Schema paths | `schemas` | Required |
| `--output`, `-o` | `output` | Required unless `--stdout` |
| `--sendable` / `--no-sendable` | `sendable` | `false` |
| `--warnings-as-errors` / `--no-warnings-as-errors` | `warningsAsErrors` | `false` |
| `--check` | — | Check output without writing |
| `--stdout` | — | Emit source on standard output |
| `--diagnostics-format json` | — | Human-readable diagnostics by default |

Diagnostics go to standard error, keeping generated source separate. Use `--check`
to fail CI when checked-in models are stale:

```sh
swift run -q SwiftJSONSchemaGen --config swift-json-schema-gen.json --check
```

Configuration uses Apple's Swift Configuration package; command-line parsing uses
Apple's ArgumentParser. JSON is the supported configuration format.

## Choose an integration

### Swift library

Add this repository as a SwiftPM dependency. Replace `YOUR-ORG` with the owner of
your published repository; version `0.1.0` becomes available after the first release.

```swift
.package(url: "https://github.com/YOUR-ORG/SwiftJSONSchemaGen.git", from: "0.1.0")
```

Add the library product to your target:

```swift
.product(name: "JSONSchemaGeneration", package: "SwiftJSONSchemaGen")
```

Generate entirely in memory with `JSONSchemaGenerator`:

```swift
import Foundation
import JSONSchemaGeneration

let schema = Data(#"{"title":"Identifier","type":"string"}"#.utf8)
let result = try JSONSchemaGenerator().generate(
    resources: [SchemaResource(data: schema, url: URL(fileURLWithPath: "/schemas/id.json"))],
    options: GenerationOptions(sendable: true)
)
print(result.source)
for diagnostic in result.diagnostics {
    print(diagnostic.message)
}
```

The library does not write files or fetch references during generation. Supply all
referenced resources, or use the `generate(schemaURLs:options:)` file-loading
convenience method. `GeneratedSourceWriter` handles writing a result to disk.

### SwiftPM build tool plugin

Attach `SwiftJSONSchemaGenPlugin` to the target that uses the models:

```swift
.target(
    name: "Models",
    exclude: ["Schemas", "swift-json-schema-gen.json"],
    plugins: [
        .plugin(name: "SwiftJSONSchemaGenPlugin", package: "SwiftJSONSchemaGen")
    ]
)
```

Place `swift-json-schema-gen.json` in that target's source directory:

```json
{
  "schemas": ["Schemas/person.schema.json"],
  "sendable": true,
  "warningsAsErrors": true
}
```

The plugin owns the output path in SwiftPM's work directory. Include every referenced
schema in `schemas`; the config and schema files become build inputs. No generated
file needs to be checked in. Keep schema files excluded from the target's ordinary
resources, as shown above.

## Schema support

This is a **model generator**, not a complete JSON Schema validator. It recognizes
Draft 7, Draft 2019-09, and Draft 2020-12 and diagnoses unsupported semantics. An
omitted `$schema` selects Draft 2020-12. Unknown explicit dialects are errors.

Read the [supported-keyword matrix](Docs/SchemaSupport.md) before generating models
for an unfamiliar schema. Use `--warnings-as-errors` when a build must reject
unenforced assertions. Successfully decoding a model does not establish full schema
validity when you accepted generation warnings.

Supply referenced documents explicitly:

```sh
swift run -q SwiftJSONSchemaGen --sendable --output Models.swift \
  Schemas/order.json Schemas/customer.json
```

`$id` gives resources canonical identities; references to supplied resources can use
those identities without network access. Missing resources fail with a diagnostic.

### Names and arbitrary JSON

Schema titles name root types. `definitions` and `$defs` become nested declarations;
original property spelling is retained in Codable mappings. Convenience aliases are
emitted where names are unambiguous.

Untyped JSON uses a generated `AnyValue` with cases for JSON scalars, arrays, objects,
and null. It includes accessors and subscripts such as `value["name"].stringValue`.
`AnyValue` is the sole representation for unconstrained JSON. For example, if a
schema contains `"metadata": true`, its generated property can hold an object:

```swift
let metadata = AnyValue.object(["name": .string("Ada"), "active": .boolean(true)])
print(metadata["name"].stringValue)
```

`--sendable` adds Sendable conformance to generated types, including `AnyValue`.

## Development and releases

```sh
swift test -q
mise run format
```

The tests compile and run generated models, exercise reference resolution and
configuration, and use only package-owned fixtures. See [CONTRIBUTING.md](CONTRIBUTING.md)
for verification and the tagged release procedure. GitHub Actions verifies macOS and
Linux before packaging release artifacts.

[ARCHITECTURE.md](ARCHITECTURE.md) maps the implementation.
[CHANGELOG.md](CHANGELOG.md) records compatibility changes.

## License

MIT. See [LICENSE](LICENSE). Third-party dependencies and bundled resources retain
their own licenses.
