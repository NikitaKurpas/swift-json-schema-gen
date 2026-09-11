<p align="center">
  <img src="Docs/logo.svg" alt="SwiftJSONSchemaGen — JSON Schema to Swift Codable" width="840" />
</p>

# SwiftJSONSchemaGen

Generate Swift Codable models from JSON Schema—with strict union decoding,
recursive types, offline references, and SwiftPM build integration.

Use the CLI, embed the `JSONSchemaGeneration` library, or generate models during
your build. Generated code depends on Foundation only.

**Swift 6.3+ · macOS 15+ or Linux · MIT**

The requirements above apply to the generator; generated Foundation/Codable models
have separate platform requirements.

## 🚀 Quickstart

From a checkout of this repository, generate the [example schema](Examples/Schemas/pet.json):

```sh
swift run -q SwiftJSONSchemaGen --config Examples/swift-json-schema-gen.json
```

Add `Examples/Generated/SchemaTypes.swift` to your app target, then decode a pet:

```swift
import Foundation

let json = Data(#"{"id":42,"name":"Mochi"}"#.utf8)
let pet = try JSONDecoder().decode(Pet.self, from: json)
print(pet.name) // Mochi
```

For your own schema:

```sh
swift run -q SwiftJSONSchemaGen --output Models.swift Schemas/pet.json
```

To build an optimized executable, run `swift build -q -c release`. If using a binary
release archive, extract it and run `./SwiftJSONSchemaGen` with the same arguments.
Keep the resource bundle beside the executable, including when adding its directory
to `PATH`. Choose the archive for your operating system and architecture.

## ✨ Features

### 🔍 Missing and null mean different things

An optional property can still reject null. A required property can allow null and
still require its key to exist:

```json
{
  "title": "Profile",
  "type": "object",
  "properties": {
    "nickname": { "type": "string" },
    "bio": { "type": ["string", "null"] }
  },
  "required": ["bio"],
  "additionalProperties": false
}
```

| JSON input | Decoding result |
| --- | --- |
| `{"bio":null}` | Accepted: nickname is absent, bio is explicitly null |
| `{"bio":"Hello","nickname":"Mochi"}` | Accepted |
| `{"bio":null,"nickname":null}` | Rejected: nickname must be a string when present |
| `{}` | Rejected: bio is required |

Required names must be declared in the same schema's `properties`.

### 🎯 Unions reject ambiguous matches

`oneOf` requires exactly one branch to decode successfully:

```json
{
  "title": "Measurement",
  "oneOf": [{ "type": "integer" }, { "type": "number" }]
}
```

Decoding `1.5` succeeds through the number branch. Decoding `1` fails because both
branches match. Use `anyOf` when selecting the first successful branch is intended.
Matching follows the constraints implemented by generated decoders; unsupported
assertions produce generation diagnostics.

### 📐 Tuples keep their positions

A coordinate can require exactly two numbers instead of becoming an unrestricted array:

```json
{
  "title": "Coordinate",
  "type": "array",
  "prefixItems": [{ "type": "number" }, { "type": "number" }],
  "minItems": 2,
  "items": false
}
```

`[35.68,139.76]` decodes; a missing coordinate, a third element, or a string does not.
Draft 7 and 2019-09 tuple syntax is also supported. Recursive objects and tuples use
reference types where needed; recursive unions use indirect enums.

### 🔗 Share schemas without network-dependent builds

Reference another resource by its `$id`, such as
`{"$ref":"https://example.com/schemas/customer.json#/$defs/Customer"}`, and supply
both documents:

```sh
swift run -q SwiftJSONSchemaGen --output Models.swift \
  Schemas/order.json Schemas/customer.json
```

The customer document declares `"$id":"https://example.com/schemas/customer.json"`.
The generator resolves it offline, including anchors and escaped JSON Pointers.
Missing resources fail explicitly. `$defs` and `definitions` produce namespaced
Swift declarations with convenience aliases where names are unambiguous.

### 🧰 More than fixed object fields

| Capability | What it lets you express |
| --- | --- |
| Typed additional properties | `"additionalProperties":{"type":"integer"}` retains extra fields as integers alongside declared properties |
| Arbitrary JSON | `"metadata":true` inside `properties` uses generated `AnyValue`; read it with accessors such as `value["name"].stringValue` |
| Scalar enums and constants | `"const":404` generates a finite value representation whose decoder checks the literal |
| Object intersections | Supported `allOf` shapes combine properties and required keys; incompatible or unrepresentable intersections fail |
| Concurrency and visibility | `--sendable` adds Sendable conformance; `--access-level internal` keeps generated APIs inside your module |
| Reproducible output | Stable ordering, unchanged-file preservation, and `--check` for stale checked-in models |

See the [schema-support matrix](Docs/SchemaSupport.md) for restrictions and decoding guarantees.

## ⚙️ Configuration and CI

Keep settings next to your schemas in `swift-json-schema-gen.json`:

```json
{
  "schemas": ["Schemas/pet.json"],
  "output": "Sources/Models/Generated.swift",
  "sendable": true,
  "accessLevel": "internal",
  "warningsAsErrors": true
}
```

```sh
swift run -q SwiftJSONSchemaGen --config swift-json-schema-gen.json
# Fail CI if checked-in models need regeneration, without changing files:
swift run -q SwiftJSONSchemaGen --config swift-json-schema-gen.json --check
```

Configuration paths are relative to the config file. Explicit CLI options override
config values; positional schema paths replace its input list. CLI paths are relative
to the working directory. JSON is the supported configuration format.

| CLI | Config key | Default |
| --- | --- | --- |
| Schema paths | `schemas` | Required |
| `--output`, `-o` | `output` | Required unless `--stdout` |
| `--sendable` / `--no-sendable` | `sendable` | `false` |
| `--access-level public\|internal` | `accessLevel` | `public` |
| `--warnings-as-errors` / `--no-warnings-as-errors` | `warningsAsErrors` | `false` |
| `--check` | — | Check output without writing |
| `--stdout` | — | Emit source on standard output |
| `--diagnostics-format json` | — | Human-readable diagnostics by default |

Diagnostics go to standard error, leaving standard output available for generated
source. Run `SwiftJSONSchemaGen --help` for all options.

## 📦 Swift library

Add the package dependency and library product to your `Package.swift`:

```swift
// dependencies:
.package(url: "https://github.com/YOUR-ORG/SwiftJSONSchemaGen.git", from: "0.1.0")

// your target's dependencies:
.product(name: "JSONSchemaGeneration", package: "SwiftJSONSchemaGen")
```

Replace `YOUR-ORG` with the published repository owner; `0.1.0` requires the first
release. The package is named `SwiftJSONSchemaGen`; the import is `JSONSchemaGeneration`.

Generate in memory from schema bytes supplied by your application:

```swift
import Foundation
import JSONSchemaGeneration

let schema = Data(#"{"title":"Identifier","type":"string"}"#.utf8)
let result = try JSONSchemaGenerator().generate(
    resources: [SchemaResource(data: schema, url: URL(fileURLWithPath: "/schemas/id.json"))],
    options: GenerationOptions(sendable: true, accessLevel: .internal)
)
print(result.source)
for diagnostic in result.diagnostics {
    print(diagnostic.message)
}
```

Generation performs no file writes or network fetches. Supply all referenced resources.
For files, use `generate(schemaURLs:options:)`; `GeneratedSourceWriter` handles output.

## 🔌 SwiftPM build tool plugin

With the same package dependency, attach the plugin to your consumer target:

```swift
.target(
    name: "Models",
    exclude: ["Schemas", "swift-json-schema-gen.json"],
    plugins: [
        .plugin(name: "SwiftJSONSchemaGenPlugin", package: "SwiftJSONSchemaGen")
    ]
)
```

Place this `swift-json-schema-gen.json` in `Sources/Models/`:

```json
{
  "schemas": ["Schemas/pet.json"],
  "sendable": true,
  "warningsAsErrors": true
}
```

Include every referenced schema in `schemas`. SwiftPM tracks the config and schemas
as build inputs and regenerates models when they change. The plugin owns the output
path in its work directory, so generated files do not need to be checked in. Exclude
the inputs from ordinary target resources as shown above.

## 📚 Schema support

Draft 7, 2019-09, and 2020-12 are recognized; an omitted `$schema` selects 2020-12.
Unknown explicit dialects fail.

This is a structural model generator, not a complete JSON Schema validator.
Unsupported assertions produce diagnostics, and unrepresentable shapes fail.
Use `--warnings-as-errors` to reject unenforced assertions during generation;
accepting warnings means decoded models may accept values the schema forbids.

The [support matrix](Docs/SchemaSupport.md) documents each keyword's behavior,
including reference naming, tuple restrictions, and unsupported validation families.

## 🤝 Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development commands, verification, and
release procedures. Tests compile and run generated Swift; GitHub Actions checks
macOS, Linux, library consumers, and plugin integration before release packaging.

[Architecture](ARCHITECTURE.md) · [Changelog](CHANGELOG.md)

## ⚖️ License

[MIT](LICENSE). Dependencies and bundled resources retain their own licenses.
