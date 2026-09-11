# Changelog

All notable changes to SwiftJSONSchemaGen will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Generated `public` / `internal` access selection through `GenerationOptions`,
  `--access-level`, and the `accessLevel` configuration key; `public` remains default.
- Public Swift library API for in-memory and file-based schema generation.
- Command-line generation from direct arguments or a JSON configuration file.
- SwiftPM build-tool plugin for generation during consumer builds.
- Draft 7, Draft 2019-09, and Draft 2020-12 schema support with offline reference resolution.
- Swift 6.3 macOS and Linux CI, portable release archives, and SHA-256 checksums.

### Changed

- Swift 6.3 is required. The library product and import are `JSONSchemaGeneration`,
  with `JSONSchemaGenerator` as the entry point. Package and executable names remain
  `SwiftJSONSchemaGen`.
- Recursive object declarations use reference types where needed for finite storage.
- `oneOf` rejects ambiguous matches for represented branch semantics. Unsupported
  assertions are diagnosed; this is not a complete JSON Schema validator.
- Object decoding distinguishes missing required keys from explicit null. Unknown
  object fields are captured when allowed, and closed objects reject them.
- Unsupported or unrepresentable schema combinations fail explicitly instead of
  producing an approximate model. See `Docs/SchemaSupport.md` for the contract.
- Schema parsing uses an internal Decodable JSON value tree. Generated `AnyValue`
  is the sole representation for unconstrained JSON; SwiftyJSON, its output flag,
  configuration key, and representation options have been removed.
- Configuration rejects misspelled keys and invalid value types.

### Fixed

- Named reference, boolean, and empty definitions emit usable aliases instead of
  missing declarations. Recursive tuples use reference storage; unsafe alias cycles
  fail before emission.
- Alias namespaces that would lose nested declarations are rejected. Nested `allOf`
  preserves its own properties and required keys during intersection flattening.
- Plugin verification exercises generated API, unchanged builds, and regeneration
  after a schema input changes.
- Undeclared required properties and unimplemented model-shaping siblings of modern
  `$ref` and composition keywords fail explicitly instead of weakening the schema.
- Generated recursive value types no longer have infinitely sized storage.
- Schema reference fragments support percent decoding and JSON Pointer escaping.
- Structural resource comparison ignores object key order, preventing false
  duplicate-identifier errors across platforms.
- Output replacement is atomic and leaves unchanged files untouched.
- Tests no longer rely on machine-specific paths or ignored parent-repository inputs.
