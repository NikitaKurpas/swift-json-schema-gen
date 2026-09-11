import Foundation
import Testing

@testable import JSONSchemaGeneration

/// Regression cases for schemas that must either produce compilable Swift or fail explicitly.
struct AcceptedSchemaVerificationTests {
    @Test func namedDefinitionsAndReferenceFormsProduceCompilableSwift() throws {
        let source = try generate(
            """
            {
              "$schema": "https://json-schema.org/draft/2020-12/schema",
              "$defs": {
                "Obj": { "type": "object", "properties": { "id": { "type": "string" } } },
                "Alias": { "$ref": "#/$defs/Obj" },
                "escaped/name": { "type": "object", "properties": { "value": { "type": "integer" } } },
                "EscapedAlias": { "$ref": "#/$defs/escaped~1name" },
                "Anchored": { "$anchor": "anchored", "type": "object", "properties": { "flag": { "type": "boolean" } } },
                "AnchorAlias": { "$ref": "#anchored" },
                "Anything": true,
                "Empty": {},
                "Annotated": { "description": "metadata-only schema" },
                "Constrained": { "minLength": 1 },
                "Primitive": { "type": "string" },
                "Choice": { "enum": ["one", "two"] },
                "Pair": { "type": "array", "prefixItems": [{ "type": "string" }], "minItems": 1, "maxItems": 1, "items": false },
                "Combined": {
                  "allOf": [
                    { "type": "object", "properties": { "left": { "type": "string" } } },
                    { "type": "object", "properties": { "right": { "type": "integer" } } }
                  ]
                }
              }
            }
            """
        )

        try compile(
            source,
            references: [
                "Obj", "Alias", "EscapedAlias", "AnchorAlias", "Anything", "Empty",
                "Annotated", "Constrained", "Primitive", "Choice", "Pair", "Combined",
            ]
        )
    }

    @Test func requiredPropertiesWithoutDeclarationsAreRejected() throws {
        try expectRejected(
            """
            { "type": "object", "required": ["token"], "additionalProperties": true }
            """
        )
        try expectRejected(
            """
            {
              "allOf": [
                { "type": "object", "required": ["token"], "additionalProperties": true }
              ]
            }
            """
        )
    }

    @Test func referenceAndCompositionSiblingsAreNeverSilent() throws {
        let draft7 = try generate(
            """
            {
              "$schema": "http://json-schema.org/draft-07/schema#",
              "title": "Legacy",
              "definitions": { "Text": { "type": "string" } },
              "$ref": "#/definitions/Text",
              "type": "integer"
            }
            """
        )
        try compile(draft7)

        try expectRejected(
            """
            {
              "$schema": "https://json-schema.org/draft/2020-12/schema",
              "$defs": { "Integer": { "type": "integer" } },
              "$ref": "#/$defs/Integer",
              "type": "string"
            }
            """
        )
        try expectRejected(
            """
            {
              "oneOf": [{ "type": "string" }],
              "type": "integer",
              "not": { "const": 0 }
            }
            """
        )
        try expectRejected(
            """
            {
              "allOf": [{ "type": "object", "properties": { "name": { "type": "string" } } }],
              "additionalProperties": false
            }
            """
        )
        try expectRejected(
            """
            {
              "allOf": [{ "type": "object" }],
              "type": ["string"]
            }
            """
        )
        try expectRejectedOrDiagnosed(
            """
            {
              "oneOf": [{ "type": "string" }],
              "not": { "const": 0 }
            }
            """,
            keywords: ["not"]
        )
        try expectRejectedOrDiagnosed(
            """
            {
              "oneOf": [{ "type": "object", "properties": { "name": { "type": "string" } } }],
              "additionalProperties": false,
              "unevaluatedProperties": false
            }
            """,
            keywords: ["additionalProperties", "unevaluatedProperties"]
        )
        try expectRejectedOrDiagnosed(
            """
            {
              "anyOf": [{ "type": "array", "items": { "type": "string" } }],
              "items": false
            }
            """,
            keywords: ["items"]
        )
    }

    @Test func recursiveValueDeclarationsNeverProduceUncompilableSwift() throws {
        for schema in [
            """
            { "$defs": { "Node": { "type": "array", "prefixItems": [{ "$ref": "#/$defs/Node" }], "minItems": 1, "maxItems": 1, "items": false } } }
            """,
            """
            { "$defs": { "Node": { "type": "array", "items": { "$ref": "#/$defs/Node" } } } }
            """,
            """
            { "$defs": { "Node": { "type": "object", "additionalProperties": { "$ref": "#/$defs/Node" } } } }
            """,
        ] {
            try expectRejectedOrCompiles(schema)
        }
    }

    @Test func nestedDefinitionReferencesCompileOrRejectExplicitly() throws {
        try expectRejectedOrCompiles(
            """
            {
              "$defs": {
                "Outer": {
                  "type": "object",
                  "$defs": { "Inner": { "type": "string" } },
                  "properties": { "item": { "$ref": "#/$defs/Outer/$defs/Inner" } }
                }
              },
              "type": "object",
              "properties": { "item": { "$ref": "#/$defs/Outer/$defs/Inner" } }
            }
            """
        )
    }

    @Test func rootAliasesWithDefinitionsRemainPublicAndCompilable() throws {
        for (schema, rootType) in [
            (
                """
                {
                  "title": "RootScalar",
                  "$defs": { "Text": { "type": "string" } },
                  "$ref": "#/$defs/Text"
                }
                """, "RootScalar"
            ),
            (
                """
                {
                  "title": "RootList",
                  "$defs": { "Text": { "type": "string" } },
                  "type": "array",
                  "items": { "$ref": "#/$defs/Text" }
                }
                """, "RootList"
            ),
            (
                """
                {
                  "title": "MaybeText",
                  "$defs": { "Text": { "type": "string" } },
                  "anyOf": [{ "$ref": "#/$defs/Text" }, { "type": "null" }]
                }
                """, "MaybeText"
            ),
        ] {
            try compile(try generate(schema), references: [rootType])
        }
    }

    @Test func rootAliasNamespacePlanningUsesTheRootIdentifierForNullableReferences() throws {
        let result = try JSONSchemaGenerator().generate(resources: [
            SchemaResource(
                data: Data(
                    """
                    {
                      "$id": "https://example.test/schemas/root.json",
                      "title": "MaybeExternal",
                      "$defs": { "Local": { "type": "string" } },
                      "oneOf": [{ "$ref": "child.json#/$defs/Text" }, { "type": "null" }]
                    }
                    """.utf8
                ),
                url: URL(fileURLWithPath: "/inputs/root.json")
            ),
            SchemaResource(
                data: Data(#"{"$defs":{"Text":{"type":"string"}}}"#.utf8),
                url: URL(string: "https://example.test/schemas/child.json")!
            ),
        ])

        try compile(result.source, references: ["MaybeExternal"])
    }

    private func generate(_ schema: String) throws -> String {
        try JSONSchemaGenerator().generate(resources: [
            SchemaResource(
                data: Data(schema.utf8),
                url: URL(fileURLWithPath: "/schemas/adversarial.json")
            )
        ]).source
    }

    private func compile(_ source: String, references: [String] = []) throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let generated = directory.appendingPathComponent("Generated.swift")
        let runner = directory.appendingPathComponent("Runner.swift")
        let binary = directory.appendingPathComponent("runner")
        try source.write(to: generated, atomically: true, encoding: .utf8)
        let typeReferences = references.map { "        accepts(\($0).self)" }.joined(
            separator: "\n")
        try """
        @main
        struct Runner {
            static func accepts<T>(_: T.Type) {}

            static func main() {
        \(typeReferences)
            }
        }
        """.write(to: runner, atomically: true, encoding: .utf8)
        try TestSupport.compileSwift(sources: [generated, runner], output: binary)
    }

    private func expectRejected(_ schema: String) throws {
        do {
            _ = try generate(schema)
            Issue.record("Expected generation to reject a schema with no safe Swift representation")
        } catch is GenerationError {
        }
    }

    private func expectRejectedOrCompiles(_ schema: String) throws {
        do {
            try compile(try generate(schema))
        } catch is GenerationError {
        }
    }

    private func expectRejectedOrDiagnosed(_ schema: String, keywords: Set<String>) throws {
        do {
            let result = try JSONSchemaGenerator().generate(resources: [
                SchemaResource(
                    data: Data(schema.utf8),
                    url: URL(fileURLWithPath: "/schemas/adversarial.json")
                )
            ])
            let diagnosed = Set(result.diagnostics.compactMap(\.keyword))
            #expect(keywords.isSubset(of: diagnosed))
        } catch is GenerationError {
        }
    }
}
