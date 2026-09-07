import ArgumentParser
import Configuration
import Foundation

struct FileConfiguration {
    var schemas: [String]
    var output: String?
    var sendable: Bool?
    var warningsAsErrors: Bool?

    static let empty = FileConfiguration(
        schemas: [],
        output: nil,
        sendable: nil,
        warningsAsErrors: nil
    )

    static func load(from url: URL) async throws -> FileConfiguration {
        do {
            try validateShape(Data(contentsOf: url))
            let provider = try await FileProvider<JSONSnapshot>(
                filePath: .init(url.path(percentEncoded: false)))
            let reader = ConfigReader(provider: provider)
            return FileConfiguration(
                schemas: reader.stringArray(forKey: "schemas", default: []),
                output: reader.string(forKey: "output"),
                sendable: reader.bool(forKey: "sendable"),
                warningsAsErrors: reader.bool(forKey: "warningsAsErrors")
            )
        } catch {
            throw ValidationError(
                "failed to load configuration '\(url.path(percentEncoded: false))': \(error)")
        }
    }

    private static func validateShape(_ data: Data) throws {
        _ = try JSONDecoder().decode(DecodedConfiguration.self, from: data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ValidationError("configuration must be a JSON object")
        }
        let allowedKeys: Set<String> = [
            "schemas", "output", "sendable", "warningsAsErrors",
        ]
        let unknownKeys = Set(object.keys).subtracting(allowedKeys).sorted()
        guard unknownKeys.isEmpty else {
            throw ValidationError(
                "unknown configuration key(s): \(unknownKeys.joined(separator: ", "))")
        }
        if let schemas = object["schemas"], !(schemas is [String]) {
            throw ValidationError("'schemas' must be an array of strings")
        }
        if let output = object["output"], !(output is String) {
            throw ValidationError("'output' must be a string")
        }
        for key in ["sendable", "warningsAsErrors"] {
            if let value = object[key], !(value is Bool) {
                throw ValidationError("'\(key)' must be a boolean")
            }
        }
    }
}

private struct DecodedConfiguration: Decodable {
    let schemas: [String]?
    let output: String?
    let sendable: Bool?
    let warningsAsErrors: Bool?
}
