import Foundation
import Testing

@testable import JSONSchemaGeneration

struct AccessLevelTests {
    @Test func publicOutputIsUsableFromAnotherModule() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try generate(
            """
            {
              "title": "Person",
              "type": "object",
              "properties": { "name": { "type": "string" } },
              "required": ["name"],
              "additionalProperties": false
            }
            """
        )
        let module = try compileModule(source, named: "PublicModels", in: directory)
        let consumer = directory.appending(path: "Consumer.swift")
        try """
        import PublicModels

        func greeting() -> String { Person(name: "Ada").name }
        """.write(to: consumer, atomically: true, encoding: .utf8)

        try TestSupport.compileSwift(
            sources: [consumer],
            output: directory.appending(path: "Consumer.o"),
            additionalArguments: ["-c", "-I", module.deletingLastPathComponent().path]
        )
    }

    @Test func internalOutputCompilesButIsHiddenFromOtherModules() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try generate(
            """
            {
              "title": "Node",
              "type": "object",
              "properties": {
                "child": { "$ref": "#" },
                "payload": true,
                "public": { "const": "public" }
              },
              "additionalProperties": false
            }
            """,
            options: GenerationOptions(accessLevel: .internal)
        )

        #expect(source.contains("internal final class Node"))
        #expect(source.contains("internal enum AnyValue"))
        #expect(source.contains("private struct"))
        #expect(source.contains(#"= "public""#))

        let module = try compileModule(source, named: "InternalModels", in: directory)
        let consumer = directory.appending(path: "Consumer.swift")
        try """
        import InternalModels

        func consume(_ value: Node) {}
        """.write(to: consumer, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) {
            try TestSupport.compileSwift(
                sources: [consumer],
                output: directory.appending(path: "Consumer.o"),
                additionalArguments: ["-c", "-I", module.deletingLastPathComponent().path]
            )
        }
    }

    private func generate(
        _ schema: String,
        options: GenerationOptions = .init()
    ) throws -> String {
        try JSONSchemaGenerator().generate(
            resources: [
                SchemaResource(
                    data: Data(schema.utf8),
                    url: URL(fileURLWithPath: "/schemas/schema.json"))
            ],
            options: options
        ).source
    }

    private func compileModule(_ source: String, named name: String, in directory: URL) throws
        -> URL
    {
        let sourceURL = directory.appending(path: "\(name).swift")
        let moduleURL = directory.appending(path: "\(name).swiftmodule")
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        try TestSupport.compileSwift(
            sources: [sourceURL],
            output: moduleURL,
            additionalArguments: ["-parse-as-library", "-emit-module", "-module-name", name]
        )
        return moduleURL
    }
}
