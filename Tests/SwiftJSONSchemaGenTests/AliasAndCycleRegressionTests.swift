import Foundation
import Testing

@testable import JSONSchemaGeneration

struct AliasAndCycleRegressionTests {
    @Test func namedDefinitionAliasesCompileAndRun() throws {
        let source = try generate(
            """
            {
              "$schema": "https://json-schema.org/draft/2020-12/schema",
              "title": "AliasCatalog",
              "$defs": {
                "Obj": {
                  "type": "object",
                  "properties": { "id": { "type": "string" } },
                  "required": ["id"]
                },
                "Alias": { "$ref": "#/$defs/Obj" },
                "Escaped/Target": {
                  "type": "object",
                  "properties": { "value": { "type": "integer" } },
                  "required": ["value"]
                },
                "EscapedAlias": { "$ref": "#/$defs/Escaped~1Target" },
                "AnchoredTarget": {
                  "$anchor": "target",
                  "type": "object",
                  "properties": { "enabled": { "type": "boolean" } },
                  "required": ["enabled"]
                },
                "AnchorAlias": { "$ref": "#target" },
                "Anything": true,
                "Empty": {},
                "Annotated": { "description": "free-form value" },
                "Titled": { "title": "TitledValue" },
                "Constrained": { "minLength": 1 },
                "Primitive": { "type": "string" },
                "Choice": { "type": "string", "enum": ["red", "blue"] },
                "Pair": {
                  "type": "array",
                  "prefixItems": [{ "type": "string" }, { "type": "integer" }],
                  "minItems": 2,
                  "items": false
                },
                "Combined": {
                  "allOf": [{
                    "type": "object",
                    "properties": { "name": { "type": "string" } },
                    "required": ["name"]
                  }]
                }
              }
            }
            """
        )
        let runner = """
            import Foundation

            @main
            struct Runner {
                static func main() throws {
                    let decoder = JSONDecoder()
                    let alias = try decoder.decode(Alias.self, from: Data(#"{"id":"ok"}"#.utf8))
                    let escaped = try decoder.decode(EscapedAlias.self, from: Data(#"{"value":2}"#.utf8))
                    let anchored = try decoder.decode(AnchorAlias.self, from: Data(#"{"enabled":true}"#.utf8))
                    let anything = try decoder.decode(Anything.self, from: Data("null".utf8))
                    let empty = try decoder.decode(Empty.self, from: Data(#"{"free":1}"#.utf8))
                    let annotated = try decoder.decode(Annotated.self, from: Data("true".utf8))
                    let titled = try decoder.decode(Titled.self, from: Data("null".utf8))
                    let constrained = try decoder.decode(Constrained.self, from: Data(#""x""#.utf8))
                    let primitive = try decoder.decode(Primitive.self, from: Data(#""text""#.utf8))
                    let choice = try decoder.decode(Choice.self, from: Data(#""red""#.utf8))
                    let pair = try decoder.decode(Pair.self, from: Data(#"["left",2]"#.utf8))
                    let combined = try decoder.decode(Combined.self, from: Data(#"{"name":"joined"}"#.utf8))
                    print(alias.id, escaped.value, anchored.enabled, anything.isNull, empty.dictionaryValue?.count ?? -1, annotated.boolValue ?? false, titled.isNull, constrained.stringValue ?? "", primitive, choice, pair.item2, combined.name)
                }
            }
            """

        let output = try compileAndRun(source: source, runner: runner)
        #expect(output == "ok 2 true true 1 true true x text red 2 joined\n")
    }

    @Test func recursiveTupleUsesReferenceIndirectionAndCompiles() throws {
        let source = try generate(
            """
            {
              "$schema": "https://json-schema.org/draft/2020-12/schema",
              "title": "RecursiveTuple",
              "type": "array",
              "prefixItems": [{ "$ref": "#" }],
              "minItems": 1,
              "items": false
            }
            """
        )
        #expect(source.contains("public final class RecursiveTuple: Codable"))
        try compile(source: source)
    }

    @Test func recursiveCollectionShapesEitherRejectOrUseReferenceIndirection() throws {
        #expect(throws: GenerationError.self) {
            _ = try generate(
                """
                {
                  "$schema": "https://json-schema.org/draft/2020-12/schema",
                  "title": "RecursiveArray",
                  "type": "array",
                  "items": { "$ref": "#" }
                }
                """
            )
        }
        let mapSource = try generate(
            """
            {
              "$schema": "https://json-schema.org/draft/2020-12/schema",
              "title": "Container",
              "type": "object",
              "properties": {
                "values": {
                  "type": "object",
                  "additionalProperties": { "$ref": "#/properties/values" }
                }
              },
              "required": ["values"]
            }
            """
        )
        #expect(mapSource.contains("public final class Values: Codable"))
        try compile(source: mapSource)
    }

    @Test func aliasNamespaceWithNestedDefinitionFailsBeforeEmission() {
        do {
            _ = try generate(
                """
                {
                  "$schema": "https://json-schema.org/draft/2020-12/schema",
                  "title": "NamespaceCollision",
                  "type": "object",
                  "properties": {
                    "inner": { "$ref": "#/$defs/Outer/$defs/Inner" }
                  },
                  "$defs": {
                    "Outer": {
                      "description": "An unconstrained value with nested definitions",
                      "$defs": {
                        "Inner": { "type": "string" }
                      }
                    }
                  }
                }
                """
            )
            Issue.record("Expected an alias namespace collision error")
        } catch let error as GenerationError {
            #expect(error.description.contains("type alias cannot contain nested declarations"))
        } catch {
            Issue.record("Expected GenerationError, got \(error)")
        }
    }

    @Test func nestedAllOfRetainsOwnRequiredPropertiesAtRuntime() throws {
        let source = try generate(
            """
            {
              "$schema": "https://json-schema.org/draft/2020-12/schema",
              "title": "NestedIntersection",
              "allOf": [{
                "type": "object",
                "allOf": [{
                  "type": "object",
                  "properties": { "id": { "type": "integer" } },
                  "required": ["id"]
                }],
                "properties": { "name": { "type": "string" } },
                "required": ["name"]
              }]
            }
            """
        )
        let runner = """
            import Foundation

            @main
            struct Runner {
                static func main() throws {
                    let decoder = JSONDecoder()
                    let valid = try decoder.decode(
                        NestedIntersection.self,
                        from: Data(#"{"id":1,"name":"kept"}"#.utf8)
                    )
                    do {
                        _ = try decoder.decode(
                            NestedIntersection.self,
                            from: Data(#"{"id":1}"#.utf8)
                        )
                        fatalError("missing nested allOf sibling property decoded")
                    } catch {}
                    print(valid.id, valid.name)
                }
            }
            """
        #expect(try compileAndRun(source: source, runner: runner) == "1 kept\n")
    }

    @Test func objectIntersectionRejectsContradictoryMemberShapes() {
        for schema in [
            #"{"allOf":[{"type":"object"},{"type":"string","properties":{"value":{"type":"string"}}}]}"#,
            #"{"allOf":[{"type":"object"},{"enum":["x"],"properties":{"value":{"type":"string"}}}]}"#,
        ] {
            #expect(throws: GenerationError.self) {
                _ = try generate(schema)
            }
        }
    }

    @Test func rootAliasesUseASeparateDefinitionNamespace() throws {
        let fixtures = [
            (
                """
                {
                  "$schema": "https://json-schema.org/draft/2020-12/schema",
                  "title": "ScalarRoot",
                  "type": "string",
                  "$defs": { "Metadata": { "type": "integer" } }
                }
                """,
                "public enum ScalarRootDefinitions"
            ),
            (
                """
                {
                  "$schema": "http://json-schema.org/draft-07/schema#",
                  "title": "Legacy",
                  "definitions": { "Text": { "type": "string" } },
                  "$ref": "#/definitions/Text",
                  "type": "integer"
                }
                """,
                "public typealias Legacy = LegacyDefinitions.Text"
            ),
            (
                """
                {
                  "$schema": "https://json-schema.org/draft/2020-12/schema",
                  "title": "MaybeValue",
                  "anyOf": [{ "$ref": "#/$defs/Label" }, { "type": "null" }],
                  "$defs": { "Label": { "type": "string" } }
                }
                """,
                "public typealias MaybeValue = MaybeValueDefinitions.Label?"
            ),
            (
                """
                {
                  "$schema": "https://json-schema.org/draft/2020-12/schema",
                  "title": "StringList",
                  "type": "array",
                  "items": { "$ref": "#/$defs/Element" },
                  "$defs": { "Element": { "type": "string" } }
                }
                """,
                "public typealias StringList = [StringListDefinitions.Element]"
            ),
        ]

        for fixture in fixtures {
            let source = try generate(fixture.0)
            #expect(source.contains(fixture.1))
            try compile(source: source)
        }
    }

    private func generate(_ schema: String) throws -> String {
        try JSONSchemaGenerator().generate(resources: [
            SchemaResource(
                data: Data(schema.utf8),
                url: URL(string: "https://example.test/schema.json")!
            )
        ]).source
    }

    private func compile(source: String) throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let generatedURL = directory.appendingPathComponent("Generated.swift")
        let outputURL = directory.appendingPathComponent("Generated.swiftmodule")
        try source.write(to: generatedURL, atomically: true, encoding: .utf8)
        try TestSupport.compileSwift(
            sources: [generatedURL],
            output: outputURL,
            additionalArguments: ["-parse-as-library", "-emit-module"]
        )
    }

    private func compileAndRun(source: String, runner: String) throws -> String {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let generatedURL = directory.appendingPathComponent("Generated.swift")
        let runnerURL = directory.appendingPathComponent("Runner.swift")
        let binaryURL = directory.appendingPathComponent("runner")
        try source.write(to: generatedURL, atomically: true, encoding: .utf8)
        try runner.write(to: runnerURL, atomically: true, encoding: .utf8)
        try TestSupport.compileSwift(sources: [generatedURL, runnerURL], output: binaryURL)
        return try TestSupport.run(executable: binaryURL, arguments: []).stdout
    }
}
