# Schema support

SwiftJSONSchemaGen generates Codable models for a structural subset of JSON Schema.
It is not a general-purpose instance validator. The current published JSON Schema
version is [Draft 2020-12](https://json-schema.org/specification).

The generator distinguishes Draft 7, Draft 2019-09, and Draft 2020-12. An omitted
`$schema` means Draft 2020-12. Unknown explicit dialects fail instead of being treated
as a newer compatible draft.

## How to read the contract

- **Modelled:** influences the generated Swift representation.
- **Decoded:** generated Codable checks the documented condition.
- **Annotation:** metadata; it does not change accepted JSON values.
- **Diagnostic:** not implemented as an instance constraint; generation reports it.
  `--warnings-as-errors` rejects generation warnings before updating output.
- **Rejected:** generation fails because a safe representation is unavailable.

If you accept a warning, you accept that the generated type is broader than the
schema. Validate instances separately when full schema validity is required.

## Resource and dialect keywords

| Keyword / behavior | Contract |
| --- | --- |
| `$schema` | Recognizes Draft 7, 2019-09, and 2020-12; omitted value defaults to 2020-12 |
| `$id` | Offline resource identity and relative-reference base URI |
| `$ref` | Supplied documents, local pointers, and canonical resource identities |
| `$anchor` | Named anchors in supplied 2019-09 and 2020-12 resources |
| Draft 7 fragment `$id` | Legacy named anchor resolution |
| `$defs`, `definitions` | Namespaced reusable declarations |
| JSON Pointer | `~0` / `~1` escaping and URI percent-encoded fragments |
| Remote URI | An identity for explicitly supplied data; no implicit network fetch |
| `$vocabulary` | Unknown or partially implemented required vocabularies fail; required annotation-only vocabularies are accepted; unknown optional vocabularies warn |
| `$dynamicRef`, `$dynamicAnchor`, `$recursiveRef`, `$recursiveAnchor` | Diagnostic; dynamic scope is not implemented |

Malformed standard keyword shapes fail with a source JSON Pointer. Unknown keywords
produce `unknown_keyword`; keywords from another dialect produce
`wrong_dialect_keyword`. Intentional `x-*` extension annotations are silent. Inferred
object/array shapes without an explicit `type` produce `inferred_type`, because JSON
Schema's object/array keywords alone do not exclude other JSON types.

Required `core`, `applicator`, `validation`, and `unevaluated` vocabularies are rejected
as partially implemented. Required `meta-data`, `format-annotation`, and `content`
vocabularies are accepted as annotation vocabularies. Declaring a recognized dialect
is not a claim that the generator implements all its vocabularies.

## Model keywords

The implementation and behavioral fixtures are the authority for the supported
subset. General assertions listed below are not implied by a matching Swift type.

| Keyword / shape | Generated representation / behavior |
| --- | --- |
| `type: string/integer/number/boolean` | `String`, `Int`, `Double`, `Bool` |
| Objects and `properties` | Named Codable models with JSON spelling preserved |
| `required` and nullable types | Required keys must exist; non-nullable fields reject null, including optional fields when present |
| `additionalProperties` | Extra fields are retained; typed extra fields decode their value type; closed objects reject unknown keys |
| Homogeneous arrays | Swift arrays of the generated item type |
| String enums | Raw-value Swift enums |
| Scalar / null `enum` and `const` | Finite value cases with literal decoding checks |
| Object / array-valued `enum` and `const` | Rejected |
| `true` | Arbitrary JSON representation |
| `false` | Rejected where no usable Swift value can represent the schema |
| `oneOf` | Union representation with exclusive branch matching for supported shapes |
| `anyOf` | Union representation choosing the first successful supported branch |
| `allOf` | Object property intersections; incompatible types, non-object members, and `additionalProperties` within members are rejected |
| Recursive models | Recursive objects use final classes; recursive unions use indirect enums |
| Draft 7 / 2019-09 tuple `items` | Required positional prefix; `additionalItems` controls the tail |
| 2020-12 `prefixItems` | Required positional prefix; `items` controls the tail |

Tuple support currently requires `minItems` to equal the prefix length. Optional
prefix positions and a larger required tail are rejected. Standalone `items: false`
arrays produce a model that accepts only an empty array. Tuple `maxItems` bounds are
checked during decoding.

A union matches generated decoding behavior. It cannot enforce branch constraints
that were reported as unsupported. `anyOf` selects one representation and does not
retain a list of all matching branches. Memberwise initializers are not schema
validators; constructing and encoding a value does not rerun all decoding checks.

## Assertions and applicators requiring separate validation

These keywords are not a promise of generated runtime validation:

| Family | Keywords |
| --- | --- |
| Numeric assertions | `multipleOf`, `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum` |
| String assertions | `minLength`, `maxLength`, `pattern` |
| General array assertions | `minItems`, `maxItems`, `uniqueItems` |
| Array membership | `contains`, `minContains`, `maxContains` |
| Object assertions | `minProperties`, `maxProperties`, `propertyNames` |
| Object applicators | `patternProperties`, `dependencies`, `dependentRequired`, `dependentSchemas` |
| Conditional / negation | `if`, `then`, `else`, `not` |
| Evaluation tracking | `unevaluatedItems`, `unevaluatedProperties` |
| Dynamic references | `$dynamicRef`, `$dynamicAnchor`, `$recursiveRef`, `$recursiveAnchor` |
| Formats | `format`; no automatic `Date`, `UUID`, or `URL` substitution |

Tuple generation enforces its required prefix and tail policy independently of general
array constraints. Consult the generation diagnostics for the particular schema.

`format` does not select a Swift storage type. Keeping dates and identifiers as
strings avoids silently changing their JSON representation or adopting an encoder's
date strategy. Add application-level conversions where needed.

## Annotations

`title` participates in naming; descriptions can become documentation. `default`
does not fill missing JSON properties. `examples`, `readOnly`, `writeOnly`,
`deprecated`, `$comment`, `contentEncoding`, `contentMediaType`, and `contentSchema`
do not imply runtime decoding adapters or assertion checks. The generator does not
provide a complete metadata-export API.

## Deliberate limits

- Input and configuration documents are JSON, not YAML.
- Output is one Swift file per invocation.
- No remote download, schema lockfile, persistent cache, or custom vocabulary API.
- No complete JSON Schema conformance claim or performance superiority claim.
- `Int` and `Double` use Swift's finite numeric ranges and precision.
- Unconstrained JSON uses generated `AnyValue`; alternative runtime representations
  are not configurable. Generated code needs Foundation only.

Standards references: [Draft 7](https://json-schema.org/draft-07/schema),
[2019-09](https://json-schema.org/draft/2019-09/schema),
[2020-12 core](https://json-schema.org/draft/2020-12/json-schema-core), and
[2020-12 validation](https://json-schema.org/draft/2020-12/json-schema-validation).
