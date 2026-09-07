# Architecture

SwiftJSONSchemaGen turns JSON Schema resources into Swift source. The same generator
serves a command-line tool, library clients, and a SwiftPM build tool plugin. The
output is ordinary Codable code: applications do not need the generator at runtime.

## Code map

- `Sources/JSONSchemaGeneration` contains the `JSONSchemaGeneration` library module.
  Its `JSONSchemaGenerator` facade accepts
  schema resources and generation options and returns source plus diagnostics.
  File-based convenience APIs adapt to this in-memory boundary.
- `Schema` loads JSON documents, identifies dialects, records unsupported semantics,
  and resolves references against an offline resource registry. `SchemaLoader` owns
  ingestion; `RefResolver` owns resource identities and JSON Pointer lookup.
- `IR` converts schema shape into Swift declarations. `TypeBuilder` owns naming,
  composition, and links between declarations; `TypeIR` represents the language
  constructs the emitter can actually produce.
- `Codegen` renders the declaration graph with SwiftSyntax. `SwiftEmitter` owns
  generated Codable implementations and shared JSON support types. Swift source
  escaping belongs here, not in schema interpretation.
- `Support` holds generation options, errors, identifier rules, and small shared
  operations. It must not become a second schema interpreter.
- `Sources/SwiftJSONSchemaGenCLI` adapts ArgumentParser and Swift Configuration to the
  library. It owns paths, configuration precedence, console diagnostics, and output
  files. It does not own schema semantics.
- `Plugins` integrates the executable into SwiftPM. Generated files belong in the
  plugin work directory; inputs and configuration belong to the consuming target.
  The plugin reads only the input-file list to declare the build graph; the CLI
  remains the authority for configuration validation and generation options.
- `Tests` exercises schema-to-source behavior and compiles and runs generated code.
  Fixtures are package-owned, so tests do not depend on the parent repository.
- `.github` and `Scripts` verify and package the standalone project. They assume
  this directory is the repository root.

Follow data through ingestion → reference resolution → declaration building →
source emission when adding a model feature. Change the CLI only when exposing an
option; callers of the library and plugin must receive the same semantics.

## Boundaries and invariants

The generator is an offline compiler. A reference URI identifies a resource; it does
not authorize a network request. Library callers supply bytes and their identities.
This keeps generation reproducible and lets applications choose their own loading
and trust policies.

Schema support and JSON instance validation are separate contracts. A Swift type
can model an object without enforcing every assertion in its schema. Unsupported
semantics must be diagnosed, and the supported-keyword matrix describes the actual
contract. Do not silently reinterpret a schema merely because Swift has a convenient
representation for it.

The IR contains Swift model decisions, not CLI paths or rendering fragments. The
emitter must not rediscover JSON Schema rules. Recursive declarations require an
explicit finite-size representation; recursion detection alone is insufficient.

Generated source order must be deterministic. Schema dictionary order, input order,
and absolute checkout paths must not leak into output. Preserve the original JSON
spelling when sanitizing Swift names.

## Cross-cutting concerns

**Diagnostics.** Carry resource identity and JSON Pointer through ingestion so a
caller can locate an unsupported keyword. The CLI presents diagnostics; the library
returns them. Strict generation promotes warnings to errors before writing output.

**Compatibility.** Public library API, command/configuration names, and generated
Swift API are all user-facing contracts. Correctness fixes can change generated
source. Document those changes and compile representative consumers before release.

**Dependencies.** ArgumentParser handles command syntax, Swift Configuration handles
configuration lookup, and SwiftSyntax handles source formatting. Foundation's
`JSONDecoder` decodes schema input into the internal `JSONValue` enum. It preserves
missing lookups separately from explicit null and keeps Boolean and numeric values
distinct. JSON Pointer traversal and structural resource comparison use this tree;
object key ordering must not affect equality. The generated `AnyValue` is a separate,
public runtime representation for unconstrained instance data.
Keep generic machinery in maintained dependencies and schema-specific decisions here.

**Verification.** Text assertions check deliberate naming and source contracts;
compiler and encode/decode tests establish behavior. A fixture that only repeats the
implementation is not a substitute for exercising the generated program. Consumer
checks cover the public library and plugin boundaries.
