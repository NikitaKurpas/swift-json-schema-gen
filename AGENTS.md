# Working on SwiftJSONSchemaGen

## Read for the task

- Read [README.md](README.md) before changing public API, CLI/configuration, or
  consumer workflows. Package and executable names are `SwiftJSONSchemaGen`; the
  library product/module is `JSONSchemaGeneration`, entered through `JSONSchemaGenerator`.
- Read [ARCHITECTURE.md](ARCHITECTURE.md) before changing module boundaries,
  schema ingestion, reference resolution, IR, or emission.
- Read [Docs/SchemaSupport.md](Docs/SchemaSupport.md) before changing schema semantics
  or claiming support for a keyword. This is a model generator with explicit support
  limits; generated decoding does not establish complete JSON Schema validity.
- Read [CONTRIBUTING.md](CONTRIBUTING.md) for contribution and release procedures.
  An already-authorized implementation request does not require opening an issue.

## Implementation rules

- Optimize for UX, then DX, then agent usability. Keep generation semantics shared
  by the library, CLI, and plugin; place policy with its owning layer.
- Preserve missing versus null and Boolean versus number in the internal Decodable
  `JSONValue`. Keep resource comparison independent of object key order.
- Generated `AnyValue` is the sole representation for unconstrained JSON. Generated
  models depend on Foundation only; keep internal parsing types out of their API.
- Resolve references only against explicitly supplied resources. Preserve
  deterministic output and diagnostics that identify the source and JSON Pointer.
- Use maintained dependencies for generic functionality; inspect existing package
  dependencies before adding one. Keep schema-specific behavior in this package.
- Use Swift 6.3+, four-space indentation, explicit access control, and focused
  files. Prefer concrete, local improvements over speculative abstractions.
- Update the relevant contract documents and `CHANGELOG.md` when changing public
  names, schema support, generated encoding/decoding, or integration behavior.
- Preserve unrelated edits. Commit, push, tag, and publish only when requested.

## Verification

Use `mise.toml` and `Scripts/` as the command authority. Use `-q` for SwiftPM
commands; request escalation for Swift toolchain commands when the execution
environment requires it.

- For behavior changes, add focused Swift Testing coverage. Prefer compiling and
  executing generated models over assertions that merely mirror emitter text.
  Keep fixtures portable and package-owned.
- Run `swift test -q` for generator changes. For public API, target, or dependency
  changes, also run `Scripts/test-library.sh` and `Scripts/test-plugin.sh`.
- For packaging, resource-bundle, or release changes, run
  `Scripts/test-release.sh dev`; relocation must work without the original bundle.
- Verify platform-sensitive changes on macOS and Linux. A temporary Docker
  container matching CI's Ubuntu/Swift versions is suitable; retain concise logs
  and remove only task-owned containers and temporary files.
- Finish source changes with `mise run format`, `mise run lint`, and
  `git diff --check`. Documentation-only changes need link and diff checks, not
  compiler tests.
- After relevant checks pass, repeat them only for new changes, failures, or an
  unresolved risk. Report actual results and distinguish environment failures from
  product failures.
