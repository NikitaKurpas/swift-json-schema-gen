import Foundation
import JSONSchema
import Testing

@testable import JSONSchemaGeneration

struct GeneratorLibraryTests {
    @Test func generatesFromAnInMemoryResourceWithoutFileSystemInput() throws {
        let schema = Data(
            """
            {
              "$schema": "https://json-schema.org/draft/2020-12/schema",
              "title": "Message",
              "type": "object",
              "properties": {
                "text": { "type": "string" }
              },
              "required": ["text"]
            }
            """.utf8
        )

        let result = try JSONSchemaGenerator().generate(resources: [
            SchemaResource(data: schema, url: URL(fileURLWithPath: "/schemas/message.json"))
        ])

        #expect(result.source.contains("public struct Message: Codable"))
        #expect(result.source.contains("public let text: String"))
    }

    @Test func fileAdapterResolvesRelativeReferences() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let addressURL = directory.appendingPathComponent("address.json")
        let personURL = directory.appendingPathComponent("person.json")
        try Data(
            """
            {
              "$schema": "https://json-schema.org/draft/2020-12/schema",
              "$id": "address.json",
              "title": "Address",
              "type": "object",
              "properties": { "city": { "type": "string" } },
              "required": ["city"]
            }
            """.utf8
        ).write(to: addressURL)
        try Data(
            """
            {
              "$schema": "https://json-schema.org/draft/2020-12/schema",
              "title": "Person",
              "type": "object",
              "properties": { "address": { "$ref": "address.json" } },
              "required": ["address"]
            }
            """.utf8
        ).write(to: personURL)

        let result = try JSONSchemaGenerator().generate(schemaURLs: [personURL, addressURL])

        #expect(result.source.contains("public struct Person: Codable"))
        #expect(result.source.contains("public let address: Address"))
    }

    @Test func fileAdapterRejectsRemoteURLsWithoutFetching() {
        #expect(throws: GenerationError.self) {
            _ = try SchemaResource(contentsOf: URL(string: "https://example.test/schema.json")!)
        }
    }

    @Test func writerCreatesParentDirectoriesAndReplacesExistingOutput() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("Generated/Sources/Models.swift")
        let writer = GeneratedSourceWriter()

        try writer.write(GenerationResult(source: "first", diagnostics: []), to: output)
        try writer.write(GenerationResult(source: "second", diagnostics: []), to: output)

        #expect(try String(contentsOf: output, encoding: .utf8) == "second")
    }

    @Test func sendableOutputCompilesAndRunsUnderSwiftSix() throws {
        let schema = Data(
            """
            {
              "$schema": "https://json-schema.org/draft/2020-12/schema",
              "title": "Envelope",
              "type": "object",
              "properties": { "payload": {} },
              "required": ["payload"]
            }
            """.utf8
        )
        let result = try JSONSchemaGenerator().generate(
            resources: [
                SchemaResource(data: schema, url: URL(fileURLWithPath: "/schemas/envelope.json"))
            ],
            options: GenerationOptions(sendable: true)
        )
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let generatedURL = directory.appendingPathComponent("Generated.swift")
        let runnerURL = directory.appendingPathComponent("Runner.swift")
        let binaryURL = directory.appendingPathComponent("runner")
        try result.source.write(to: generatedURL, atomically: true, encoding: .utf8)
        try """
        import Foundation

        func requiresSendable<T: Sendable>(_: T.Type) {}

        @main
        struct Runner {
            static func main() throws {
                requiresSendable(Envelope.self)
                let data = #"{"payload":{"count":3}}"#.data(using: .utf8)!
                let value = try JSONDecoder().decode(Envelope.self, from: data)
                FileHandle.standardOutput.write(Data(String(value.payload["count"].intValue ?? -1).utf8))
            }
        }
        """.write(to: runnerURL, atomically: true, encoding: .utf8)

        try TestSupport.compileSwift(sources: [generatedURL, runnerURL], output: binaryURL)
        let execution = try TestSupport.run(executable: binaryURL, arguments: [])
        #expect(execution.stdout == "3")
    }

    @Test func warningsAsErrorsPreservesStructuredDiagnostics() throws {
        let schema = Data(
            #"{"$schema":"https://json-schema.org/draft/2020-12/schema","title":"Name","type":"string","minLength":1}"#
                .utf8
        )

        do {
            _ = try JSONSchemaGenerator().generate(
                resources: [
                    SchemaResource(data: schema, url: URL(string: "https://example.test/name")!)
                ],
                options: GenerationOptions(warningsAsErrors: true)
            )
            Issue.record("Expected warnings-as-errors to stop generation")
        } catch GenerationError.diagnostics(let diagnostics) {
            let diagnostic = try #require(diagnostics.first)
            #expect(diagnostic.severity == .error)
            #expect(diagnostic.code == "unsupported_keyword")
            #expect(diagnostic.keyword == "minLength")
            #expect(diagnostic.pointer == "/minLength")
            #expect(diagnostic.sourceURL == URL(string: "https://example.test/name"))
        } catch {
            Issue.record("Expected structured diagnostics, got \(error)")
        }
    }

    @Test func generatedIdentifiersCompileAndPreserveTheirJSONKeys() throws {
        let schemaText = """
            {
              "$schema": "https://json-schema.org/draft/2020-12/schema",
              "title": "KeywordPayload",
              "type": "object",
              "properties": {
                "class": { "type": "string" },
                "switch": { "type": "integer" },
                "1st-value": { "type": "boolean" },
                "user.name": { "type": "string" }
              },
              "required": ["class", "switch", "1st-value", "user.name"]
            }
            """
        let result = try JSONSchemaGenerator().generate(resources: [
            SchemaResource(
                data: Data(schemaText.utf8),
                url: URL(fileURLWithPath: "/schemas/keywords.json")
            )
        ])
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let generatedURL = directory.appendingPathComponent("Generated.swift")
        let runnerURL = directory.appendingPathComponent("Runner.swift")
        let binaryURL = directory.appendingPathComponent("runner")
        try result.source.write(to: generatedURL, atomically: true, encoding: .utf8)
        try """
        import Foundation

        @main
        struct Runner {
            static func main() throws {
                let input = #"{"class":"notice","switch":2,"1st-value":true,"user.name":"Taylor"}"#.data(using: .utf8)!
                let value = try JSONDecoder().decode(KeywordPayload.self, from: input)
                FileHandle.standardOutput.write(try JSONEncoder().encode(value))
            }
        }
        """.write(to: runnerURL, atomically: true, encoding: .utf8)

        try TestSupport.compileSwift(sources: [generatedURL, runnerURL], output: binaryURL)
        let encoded = try TestSupport.run(executable: binaryURL, arguments: []).stdout
        let validation = try Schema(instance: schemaText).validate(instance: encoded)
        #expect(validation.isValid)
    }
}
