import Foundation
import Testing

@testable import SwiftJSONSchemaGenCLI

struct ConfigurationTests {
    @Test func configPathsAreRelativeToConfigAndExplicitNegationOverridesBoolean() async throws {
        let directory = try makeTemporaryDirectory()
        let schemasDirectory = directory.appending(path: "Schemas", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: schemasDirectory, withIntermediateDirectories: true)
        try schema(title: "Configured").write(
            to: schemasDirectory.appending(path: "configured.json"),
            atomically: true,
            encoding: .utf8
        )
        let configURL = directory.appending(path: "swift-json-schema-gen.json")
        try """
        {
          "schemas": ["Schemas/configured.json"],
          "output": "Generated/Types.swift",
          "sendable": true
        }
        """.write(to: configURL, atomically: true, encoding: .utf8)

        var command = try JSONSchemaGeneratorCommand.parse([
            "--config", configURL.path,
            "--no-sendable",
        ])
        try await command.run()

        let output = try String(
            contentsOf: directory.appending(path: "Generated/Types.swift"), encoding: .utf8)
        #expect(output.contains("public struct Configured: Codable"))
        #expect(!output.contains("public struct Configured: Codable, Sendable"))
    }

    @Test func configRejectsUnknownKeysInsteadOfIgnoringTypos() async throws {
        let directory = try makeTemporaryDirectory()
        let configURL = directory.appending(path: "swift-json-schema-gen.json")
        try """
        { "schemas": [], "warningAsErrors": true, "output": "Types.swift" }
        """.write(to: configURL, atomically: true, encoding: .utf8)

        var command = try JSONSchemaGeneratorCommand.parse(["--config", configURL.path])
        await #expect(throws: (any Error).self) {
            try await command.run()
        }
    }

    @Test(arguments: [0, 1])
    func configRejectsNumericBooleanLookalikes(_ value: Int) async throws {
        let directory = try makeTemporaryDirectory()
        let configURL = directory.appending(path: "swift-json-schema-gen.json")
        try """
        { "schemas": [], "sendable": \(value), "output": "Types.swift" }
        """.write(to: configURL, atomically: true, encoding: .utf8)

        await #expect(throws: (any Error).self) {
            _ = try await FileConfiguration.load(from: configURL)
        }
    }

    @Test func checkDetectsStaleOutputAndAcceptsCurrentOutput() async throws {
        let directory = try makeTemporaryDirectory()
        let schemaURL = directory.appending(path: "schema.json")
        let outputURL = directory.appending(path: "Types.swift")
        try schema(title: "Checked").write(to: schemaURL, atomically: true, encoding: .utf8)

        var generate = try JSONSchemaGeneratorCommand.parse([
            "--output", outputURL.path,
            schemaURL.path,
        ])
        try await generate.run()

        var currentCheck = try JSONSchemaGeneratorCommand.parse([
            "--check", "--output", outputURL.path,
            schemaURL.path,
        ])
        try await currentCheck.run()

        try "// stale\n".write(to: outputURL, atomically: true, encoding: .utf8)
        var staleCheck = try JSONSchemaGeneratorCommand.parse([
            "--check", "--output", outputURL.path,
            schemaURL.path,
        ])
        await #expect(throws: (any Error).self) {
            try await staleCheck.run()
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL.temporaryDirectory.appending(
            path: "swift-json-schema-gen-cli-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func schema(title: String) -> String {
        """
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "title": "\(title)",
          "type": "object",
          "properties": { "id": { "type": "string" } },
          "required": ["id"]
        }
        """
    }
}
