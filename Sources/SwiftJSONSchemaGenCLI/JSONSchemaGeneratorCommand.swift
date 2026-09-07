import ArgumentParser
import Foundation
import JSONSchemaGeneration

public struct JSONSchemaGeneratorCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "SwiftJSONSchemaGen",
        abstract: "Generate Swift Codable types from JSON Schema documents.",
        discussion:
            "Pass schema paths directly, or use --config. Command-line values override configuration-file values.",
        version: "0.1.0"
    )

    @Option(
        name: [.customShort("c"), .customLong("config")], help: "JSON configuration file path.")
    var configPath: String?

    @Option(name: [.customShort("o"), .customLong("output")], help: "Generated Swift file path.")
    var outputPath: String?

    @Flag(help: "Write generated source to standard output.")
    var stdout = false

    @Flag(help: "Check that the output file is current without writing it.")
    var check = false

    @Flag(inversion: .prefixedNo, help: "Add Sendable conformance to generated types.")
    var sendable: Bool?

    @Flag(inversion: .prefixedNo, help: "Fail generation when a schema produces a warning.")
    var warningsAsErrors: Bool?

    @Option(help: "Diagnostic output format: human or json.")
    var diagnosticsFormat: DiagnosticsFormat = .human

    @Argument(help: "JSON Schema file paths. These replace paths from the configuration file.")
    var schemas: [String] = []

    public init() {}

    public mutating func run() async throws {
        let invocation = try await resolvedInvocation()
        let result = try JSONSchemaGenerator().generate(
            schemaURLs: invocation.schemaURLs,
            options: invocation.options
        )

        try emitDiagnostics(result.diagnostics)
        if check, let outputURL = invocation.outputURL {
            let current = try? String(contentsOf: outputURL, encoding: .utf8)
            guard current == result.source else {
                throw ValidationError(
                    "generated output is stale: \(outputURL.path(percentEncoded: false))")
            }
        } else if let outputURL = invocation.outputURL {
            try GeneratedSourceWriter().write(result, to: outputURL)
        }
        if stdout {
            print(result.source, terminator: result.source.hasSuffix("\n") ? "" : "\n")
        }
    }

    private func resolvedInvocation() async throws -> ResolvedInvocation {
        let currentDirectory = URL(
            filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
        let fileConfiguration: FileConfiguration
        let configurationDirectory: URL

        if let configPath {
            let configURL = resolve(path: configPath, relativeTo: currentDirectory)
            fileConfiguration = try await FileConfiguration.load(from: configURL)
            configurationDirectory = configURL.deletingLastPathComponent()
        } else {
            fileConfiguration = .empty
            configurationDirectory = currentDirectory
        }

        let rawSchemas = schemas.isEmpty ? fileConfiguration.schemas : schemas
        let schemaBase = schemas.isEmpty ? configurationDirectory : currentDirectory
        guard !rawSchemas.isEmpty else {
            throw GenerationError.invalidArguments(
                "at least one schema path is required (as an argument or in --config)")
        }
        let schemaURLs = try rawSchemas.map { rawPath in
            let url = resolve(path: rawPath, relativeTo: schemaBase)
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
                throw ValidationError("schema file not found: \(rawPath)")
            }
            return url
        }

        let resolvedOutputPath = outputPath ?? fileConfiguration.output
        let outputBase = outputPath == nil ? configurationDirectory : currentDirectory
        let outputURL = resolvedOutputPath.map { resolve(path: $0, relativeTo: outputBase) }
        if check, stdout {
            throw ValidationError("--check cannot be combined with --stdout")
        }
        if check, outputURL == nil {
            throw ValidationError("--check requires an output path")
        }
        guard outputURL != nil || stdout else {
            throw ValidationError(
                "provide --output, set 'output' in the configuration file, or pass --stdout")
        }
        if let outputURL {
            let protectedInputs = Set(
                schemaURLs
                    + (configPath.map { [resolve(path: $0, relativeTo: currentDirectory)] } ?? []))
            guard !protectedInputs.contains(outputURL) else {
                throw ValidationError(
                    "output path must not overwrite a schema or configuration file")
            }
        }

        return ResolvedInvocation(
            schemaURLs: schemaURLs,
            outputURL: outputURL,
            options: GenerationOptions(
                sendable: sendable ?? fileConfiguration.sendable ?? false,
                warningsAsErrors: warningsAsErrors ?? fileConfiguration.warningsAsErrors ?? false
            )
        )
    }

    private func resolve(path: String, relativeTo directory: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(filePath: path).standardizedFileURL
        }
        return directory.appending(path: path).standardizedFileURL
    }

    private func emitDiagnostics(_ diagnostics: [GenerationDiagnostic]) throws {
        guard !diagnostics.isEmpty else { return }
        let output: String
        switch diagnosticsFormat {
        case .human:
            output =
                diagnostics.map { diagnostic in
                    let location = [
                        diagnostic.sourceURL?.path(percentEncoded: false), diagnostic.pointer,
                    ]
                    .compactMap { $0 }
                    .joined()
                    let prefix = location.isEmpty ? "" : "\(location): "
                    let code = diagnostic.code.map { "[\($0)] " } ?? ""
                    let suggestion = diagnostic.suggestion.map { " Fix: \($0)" } ?? ""
                    return
                        "\(prefix)\(diagnostic.severity.rawValue): \(code)\(diagnostic.message)\(suggestion)"
                }.joined(separator: "\n") + "\n"
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            output = String(decoding: try encoder.encode(diagnostics), as: UTF8.self) + "\n"
        }
        FileHandle.standardError.write(Data(output.utf8))
    }
}

private struct ResolvedInvocation {
    let schemaURLs: [URL]
    let outputURL: URL?
    let options: GenerationOptions
}
