import Foundation
import PackagePlugin

@main
struct SwiftJSONSchemaGenPlugin: BuildToolPlugin {
    private static let configurationFileName = "swift-json-schema-gen.json"
    private static let generatedFileName = "SwiftJSONSchemaGen.generated.swift"

    func createBuildCommands(
        context: PluginContext,
        target: any Target
    ) async throws -> [Command] {
        guard let sourceTarget = target as? any SourceModuleTarget else {
            throw PluginError.unsupportedTarget(target.name)
        }

        let configurationURL = sourceTarget.directoryURL
            .appendingPathComponent(Self.configurationFileName)
        guard FileManager.default.fileExists(atPath: configurationURL.path) else {
            throw PluginError.missingConfiguration(configurationURL)
        }

        let schemaURLs = try configuredSchemaURLs(
            configurationURL: configurationURL,
            targetDirectoryURL: sourceTarget.directoryURL
        )
        let outputURL = context.pluginWorkDirectoryURL
            .appendingPathComponent(Self.generatedFileName)
        let generator = try context.tool(named: "SwiftJSONSchemaGenCLI")

        return [
            .buildCommand(
                displayName: "Generate Swift types for \(target.name)",
                executable: generator.url,
                arguments: [
                    "--config", configurationURL.path,
                    "--output", outputURL.path,
                ],
                inputFiles: [configurationURL] + schemaURLs,
                outputFiles: [outputURL]
            )
        ]
    }

    private func configuredSchemaURLs(
        configurationURL: URL,
        targetDirectoryURL: URL
    ) throws -> [URL] {
        let data: Data
        do {
            data = try Data(contentsOf: configurationURL)
        } catch {
            throw PluginError.unreadableConfiguration(configurationURL, error)
        }

        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw PluginError.invalidConfiguration(
                configurationURL,
                "expected valid JSON: \(error.localizedDescription)"
            )
        }

        guard
            let object = value as? [String: Any],
            let schemas = object["schemas"] as? [String],
            !schemas.isEmpty
        else {
            throw PluginError.invalidConfiguration(
                configurationURL,
                "'schemas' must be a non-empty array of file paths"
            )
        }

        return schemas.map { path in
            if path.hasPrefix("/") {
                return URL(fileURLWithPath: path).standardizedFileURL
            }
            return
                targetDirectoryURL
                .appendingPathComponent(path)
                .standardizedFileURL
        }
    }
}

private enum PluginError: Error, CustomStringConvertible {
    case unsupportedTarget(String)
    case missingConfiguration(URL)
    case unreadableConfiguration(URL, any Error)
    case invalidConfiguration(URL, String)

    var description: String {
        switch self {
        case .unsupportedTarget(let name):
            return
                "SwiftJSONSchemaGenPlugin can only be attached to a source module target; '\(name)' is unsupported"
        case .missingConfiguration(let url):
            return "SwiftJSONSchemaGenPlugin requires a configuration file at '\(url.path)'"
        case .unreadableConfiguration(let url, let error):
            return
                "SwiftJSONSchemaGenPlugin could not read '\(url.path)': \(error.localizedDescription)"
        case .invalidConfiguration(let url, let reason):
            return "SwiftJSONSchemaGenPlugin configuration at '\(url.path)' is invalid: \(reason)"
        }
    }
}
