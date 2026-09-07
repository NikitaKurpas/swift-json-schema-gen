import Foundation
import Testing

@testable import JSONSchemaGeneration

struct CoreCodegenCorrectnessTests {
    @Test func generatedStructuralModelsCompileAndEnforceTheirRepresentedSemantics() throws {
        let schema = Data(
            """
            {
              "$schema": "https://json-schema.org/draft/2020-12/schema",
              "title": "Models",
              "$defs": {
                "Node": {
                  "type": "object",
                  "properties": {
                    "value": { "type": "string" },
                    "next": { "$ref": "#/$defs/Node" }
                  },
                  "required": ["value"],
                  "additionalProperties": false
                },
                "Overlap": {
                  "oneOf": [
                    { "type": "string" },
                    { "type": "string" }
                  ]
                },
                "Flexible": {
                  "anyOf": [
                    { "type": "string" },
                    { "type": "string" }
                  ]
                },
                "NullOverlap": {
                  "oneOf": [
                    { "type": "null" },
                    { "type": ["string", "null"] }
                  ]
                },
                "DuplicateNull": {
                  "oneOf": [
                    { "type": "null" },
                    { "type": "null" }
                  ]
                },
                "Pair": {
                  "type": "array",
                  "prefixItems": [
                    { "type": "string" },
                    { "type": "integer" }
                  ],
                  "minItems": 2,
                  "maxItems": 2,
                  "items": false
                },
                "Empty": {
                  "type": "array",
                  "items": false
                },
                "Numeric": {
                  "type": "integer",
                  "enum": [1, 2]
                },
                "MixedNumeric": {
                  "type": "integer",
                  "enum": [1, "excluded-by-type"]
                },
                "Flag": {
                  "type": "boolean",
                  "const": true
                },
                "Marker": {
                  "const": "__UNKNOWN_VALUE_TYPE__"
                },
                "OptionalSpelling": {
                  "oneOf": [
                    { "const": "none" },
                    { "const": "some" }
                  ]
                },
                "Open": {
                  "type": "object",
                  "properties": {
                    "name": { "type": "string" },
                    "additionalProperties": { "type": "string" }
                  },
                  "required": ["name", "additionalProperties"],
                  "additionalProperties": { "type": "integer" }
                },
                "Closed": {
                  "type": "object",
                  "properties": { "name": { "type": "string" } },
                  "required": ["name"],
                  "additionalProperties": false
                },
                "Presence": {
                  "type": "object",
                  "properties": {
                    "requiredNullable": { "type": ["string", "null"] },
                    "optionalNonNull": { "type": "string" }
                  },
                  "required": ["requiredNullable"],
                  "additionalProperties": false
                }
              }
            }
            """.utf8
        )
        let generated = try JSONSchemaGenerator().generate(resources: [
            SchemaResource(data: schema, url: URL(fileURLWithPath: "/schemas/models.json"))
        ]).source

        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let generatedURL = directory.appendingPathComponent("Generated.swift")
        let runnerURL = directory.appendingPathComponent("Runner.swift")
        let binaryURL = directory.appendingPathComponent("runner")
        try generated.write(to: generatedURL, atomically: true, encoding: .utf8)
        try """
        import Foundation

        func decodes<T: Decodable>(_ type: T.Type, _ json: String) -> Bool {
            (try? JSONDecoder().decode(type, from: Data(json.utf8))) != nil
        }

        @main
        struct Runner {
            static func main() throws {
                precondition(decodes(Node.self, #"{"value":"a","next":{"value":"b"}}"#))
                precondition(!decodes(Overlap.self, #""ambiguous""#))
                precondition(decodes(Flexible.self, #""accepted""#))
                precondition(decodes(NullOverlap.self, #""accepted""#))
                precondition(!decodes(NullOverlap.self, #"null"#))
                precondition(!decodes(DuplicateNull.self, #"null"#))
                precondition(decodes(Pair.self, #"["x",2]"#))
                precondition(!decodes(Pair.self, #"["x",2,3]"#))
                precondition(!decodes(Pair.self, #"[null,2]"#))
                precondition(!decodes(Pair.self, #"["x","wrong"]"#))
                precondition(decodes(Empty.self, #"[]"#))
                precondition(!decodes(Empty.self, #"[1]"#))
                precondition(decodes(Numeric.self, #"1"#))
                precondition(!decodes(Numeric.self, #"3"#))
                precondition(decodes(MixedNumeric.self, #"1"#))
                precondition(!decodes(MixedNumeric.self, #""excluded-by-type""#))
                precondition(decodes(Flag.self, #"true"#))
                precondition(!decodes(Flag.self, #"false"#))
                let flag = try JSONDecoder().decode(Flag.self, from: Data("true".utf8))
                let encodedFlag = try JSONEncoder().encode(flag)
                precondition(String(decoding: encodedFlag, as: UTF8.self) == "true")
                precondition(decodes(Marker.self, #""__UNKNOWN_VALUE_TYPE__""#))
                precondition(!decodes(Marker.self, #""AnyValue""#))
                precondition(decodes(OptionalSpelling.self, #""none""#))
                precondition(decodes(OptionalSpelling.self, #""some""#))

                let open = try JSONDecoder().decode(Open.self, from: Data(#"{"name":"n","additionalProperties":"fixed","score":4}"#.utf8))
                precondition(open.additionalProperties == "fixed")
                precondition(open.additionalPropertiesStorage["score"] == 4)
                let roundTrip = try JSONEncoder().encode(open)
                let object = try JSONSerialization.jsonObject(with: roundTrip) as? [String: Any]
                precondition(object?["score"] as? Int == 4)

                precondition(!decodes(Closed.self, #"{"name":"n","extra":1}"#))
                precondition(decodes(Presence.self, #"{"requiredNullable":null}"#))
                precondition(!decodes(Presence.self, #"{}"#))
                precondition(!decodes(Presence.self, #"{"requiredNullable":null,"optionalNonNull":null}"#))
                print("ok")
            }
        }
        """.write(to: runnerURL, atomically: true, encoding: .utf8)

        try TestSupport.compileSwift(sources: [generatedURL, runnerURL], output: binaryURL)
        #expect(try TestSupport.run(executable: binaryURL, arguments: []).stdout == "ok\n")
    }

    @Test func mutuallyRecursiveAndRecursiveUnionSendableModelsCompileAndRun() throws {
        let aSchema = Data(
            """
            {
              "$schema": "https://json-schema.org/draft/2020-12/schema",
              "$id": "https://example.test/a.json",
              "title": "ADocument",
              "$defs": {
                "A": {
                  "type": "object",
                  "properties": {
                    "name": { "type": "string" },
                    "b": { "$ref": "b.json#/$defs/B" },
                    "legacyPair": { "$ref": "legacy.json#/definitions/Pair" },
                    "children": {
                      "type": "object",
                      "additionalProperties": { "$ref": "#/$defs/A" }
                    }
                  },
                  "required": ["name"],
                  "additionalProperties": false
                },
                "Tree": {
                  "oneOf": [
                    { "type": "integer" },
                    {
                      "type": "array",
                      "items": { "$ref": "#/$defs/Tree" }
                    }
                  ]
                },
                "Legacy": {
                  "$schema": "http://json-schema.org/draft-07/schema#",
                  "$id": "legacy.json",
                  "type": "object",
                  "definitions": {
                    "Pair": {
                      "type": "array",
                      "items": [{ "type": "string" }],
                      "minItems": 1,
                      "maxItems": 1,
                      "additionalItems": false
                    }
                  }
                }
              }
            }
            """.utf8
        )
        let bSchema = Data(
            """
            {
              "$schema": "https://json-schema.org/draft/2020-12/schema",
              "$id": "https://example.test/b.json",
              "title": "BDocument",
              "$defs": {
                "B": {
                  "type": "object",
                  "properties": {
                    "count": { "type": "integer" },
                    "a": { "$ref": "a.json#/$defs/A" }
                  },
                  "required": ["count"],
                  "additionalProperties": false
                }
              }
            }
            """.utf8
        )
        let generated = try JSONSchemaGenerator().generate(
            resources: [
                SchemaResource(data: aSchema, url: URL(string: "https://retrieval.test/a")!),
                SchemaResource(data: bSchema, url: URL(string: "https://retrieval.test/b")!),
            ],
            options: GenerationOptions(sendable: true)
        ).source

        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let generatedURL = directory.appendingPathComponent("Generated.swift")
        let runnerURL = directory.appendingPathComponent("Runner.swift")
        let binaryURL = directory.appendingPathComponent("runner")
        try generated.write(to: generatedURL, atomically: true, encoding: .utf8)
        try """
        import Foundation

        func requiresSendable<T: Sendable>(_: T.Type) {}

        @main
        struct Runner {
            static func main() throws {
                requiresSendable(A.self)
                requiresSendable(B.self)
                requiresSendable(Tree.self)
                let a = try JSONDecoder().decode(
                    A.self,
                    from: Data(#"{"name":"root","b":{"count":1,"a":{"name":"leaf"}},"legacyPair":["legacy"],"children":{"x":{"name":"child"}}}"#.utf8)
                )
                precondition(a.b?.a?.name == "leaf")
                precondition(a.legacyPair?.item1 == "legacy")
                precondition(a.children?["x"]?.name == "child")
                _ = try JSONDecoder().decode(Tree.self, from: Data(#"[1,[2,3]]"#.utf8))
                print("ok")
            }
        }
        """.write(to: runnerURL, atomically: true, encoding: .utf8)

        try TestSupport.compileSwift(sources: [generatedURL, runnerURL], output: binaryURL)
        #expect(try TestSupport.run(executable: binaryURL, arguments: []).stdout == "ok\n")
    }

    @Test func unsupportedOrUnsatisfiableStructuralSchemasFailExplicitly() throws {
        let schemas = [
            #"{"$schema":"https://json-schema.org/draft/2020-12/schema","title":"OptionalTuple","type":"array","prefixItems":[{"type":"string"}]}"#,
            #"{"$schema":"https://json-schema.org/draft/2020-12/schema","title":"Impossible","type":"string","const":5}"#,
            #"{"$schema":"https://json-schema.org/draft/2020-12/schema","title":"Intersection","allOf":[{"type":"string"},{"type":"integer"}]}"#,
            ##"{"$schema":"https://json-schema.org/draft/2020-12/schema","title":"Alias","$ref":"#"}"##,
            ##"{"$schema":"https://json-schema.org/draft/2020-12/schema","title":"AliasIntersection","allOf":[{"$ref":"#"}]}"##,
            "false",
        ]

        for (index, schema) in schemas.enumerated() {
            #expect(throws: GenerationError.self) {
                try JSONSchemaGenerator().generate(resources: [
                    SchemaResource(
                        data: Data(schema.utf8),
                        url: URL(fileURLWithPath: "/schemas/unsupported-\(index).json")
                    )
                ])
            }
        }
    }
}
