import Foundation
import JSONSchema
import Testing

@testable import JSONSchemaGeneration
@testable import SwiftJSONSchemaGenCLI

struct SchemaSmokeCoverageTests {
    @Test func complexSchemaRoundTripCoversSupportedAndIgnoredKeywords() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let schemaURL = dir.appendingPathComponent("smoke.json")
        let outputURL = dir.appendingPathComponent("smoke.swift")
        let runnerURL = dir.appendingPathComponent("runner.swift")
        let binaryURL = dir.appendingPathComponent("runner-bin")

        let schema = """
            {
              "$schema": "https://json-schema.org/draft/2020-12/schema",
              "title": "SmokeRoot",
              "description": "Integration smoke schema for generator coverage.",
              "type": "object",
              "x-internal-note": "must be ignored by codegen",
              "unevaluatedProperties": false,
              "properties": {
                "id": {
                  "type": "string",
                  "format": "uuid",
                  "minLength": 1,
                  "pattern": "^[a-zA-Z0-9-]+$"
                },
                "count32": {
                  "type": "integer",
                  "format": "int32",
                  "minimum": 0
                },
                "count64": {
                  "type": "integer",
                  "format": "int64",
                  "minimum": 0
                },
                "score": {
                  "type": "number",
                  "minimum": 0
                },
                "enabled": {
                  "type": "boolean",
                  "default": true
                },
                "tags": {
                  "type": "array",
                  "items": { "type": "string", "minLength": 1 },
                  "minItems": 1
                },
                "tupleLike": {
                  "type": "array",
                  "prefixItems": [
                    { "type": "string" },
                    { "type": "integer" }
                  ],
                  "minItems": 2,
                  "maxItems": 2
                },
                "choiceAny": {
                  "description": "Any-of primitive union.",
                  "anyOf": [
                    { "type": "string" },
                    { "type": "integer" }
                  ]
                },
                "choiceOne": {
                  "description": "One-of referenced union.",
                  "oneOf": [
                    { "$ref": "#/$defs/Foo" },
                    { "$ref": "#/$defs/Bar" }
                  ]
                },
                "merged": {
                  "title": "MergedType",
                  "allOf": [
                    { "$ref": "#/$defs/Base" },
                    {
                      "type": "object",
                      "properties": {
                        "extra": { "type": "string" }
                      },
                      "required": ["extra"]
                    }
                  ]
                },
                "dynamic": {
                  "description": "No explicit type: should become AnyValue.",
                  "examples": [{ "nested": [1, true, null] }]
                },
                "mapObject": {
                  "type": "object",
                  "additionalProperties": { "type": "integer" }
                },
                "nullable": {
                  "type": ["string", "null"],
                  "description": "Nullable scalar"
                },
                "enumOnly": {
                  "enum": ["a", "b"]
                },
                "fromDefinitions": {
                  "$ref": "#/definitions/Legacy"
                }
              },
              "required": [
                "id",
                "count32",
                "count64",
                "choiceAny",
                "choiceOne",
                "merged",
                "dynamic",
                "fromDefinitions"
              ],
              "$defs": {
                "Foo": {
                  "title": "Foo",
                  "description": "Foo branch",
                  "type": "object",
                  "properties": {
                    "foo": { "type": "string", "minLength": 1 }
                  },
                  "required": ["foo"]
                },
                "Bar": {
                  "title": "Bar",
                  "description": "Bar branch",
                  "type": "object",
                  "properties": {
                    "bar": { "type": "integer" }
                  },
                  "required": ["bar"]
                },
                "Base": {
                  "title": "Base",
                  "type": "object",
                  "properties": {
                    "baseId": { "type": "string" }
                  },
                  "required": ["baseId"]
                }
              },
              "definitions": {
                "Legacy": {
                  "title": "Legacy",
                  "type": "object",
                  "properties": {
                    "legacy": { "type": "string" }
                  },
                  "required": ["legacy"]
                }
              }
            }
            """
        try schema.write(to: schemaURL, atomically: true, encoding: .utf8)

        var command = try JSONSchemaGeneratorCommand.parse([
            "--output",
            outputURL.path(percentEncoded: false),
            schemaURL.path(percentEncoded: false),
        ])
        try await command.run()

        let generated = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(generated.contains("public struct SmokeRoot: Codable"))
        #expect(generated.contains("public let count32: Int"))
        #expect(generated.contains("public let count64: Int"))
        #expect(generated.contains("public let dynamic: AnyValue"))
        #expect(generated.contains("public enum AnyValue: Codable"))
        #expect(!generated.contains("unevaluatedProperties"))
        #expect(!generated.contains("x-internal-note"))

        let runner = """
            import Foundation

            @main
            struct Runner {
                static func main() throws {
                    let input = #"{"id":"123e4567-e89b-12d3-a456-426614174000","count32":123,"count64":1234567890123,"score":42.5,"enabled":true,"tags":["a","b"],"tupleLike":["x",7],"choiceAny":"abc","choiceOne":{"foo":"ok"},"merged":{"baseId":"base-1","extra":"y"},"dynamic":{"nested":[1,true,null,{"k":"v"}]},"mapObject":{"a":1,"b":2},"nullable":null,"enumOnly":"a","fromDefinitions":{"legacy":"old"}}"#.data(using: .utf8)!
                    let decoded = try JSONDecoder().decode(SmokeRoot.self, from: input)
                    let data = try JSONEncoder().encode(decoded)
                    FileHandle.standardOutput.write(data)
                }
            }
            """
        try runner.write(to: runnerURL, atomically: true, encoding: .utf8)

        _ = try runProcess(
            executable: "/usr/bin/env",
            arguments: [
                "swiftc",
                "-swift-version", "6",
                "-strict-memory-safety",
                outputURL.path(percentEncoded: false),
                runnerURL.path(percentEncoded: false),
                "-o", binaryURL.path(percentEncoded: false),
            ]
        )
        let jsonInstance = try runProcess(
            executable: binaryURL.path(percentEncoded: false), arguments: []
        ).stdout

        let parsed = try Schema(instance: schema)
        let result = try parsed.validate(instance: jsonInstance)
        #expect(result.isValid)
    }

    private func makeTempDir() throws -> URL {
        try TestSupport.makeTemporaryDirectory()
    }

    private func runProcess(executable: String, arguments: [String]) throws -> (
        stdout: String, stderr: String
    ) {
        try TestSupport.run(executable: URL(fileURLWithPath: executable), arguments: arguments)
    }
}
