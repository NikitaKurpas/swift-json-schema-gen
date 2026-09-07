import Foundation

/// One JSON Schema document supplied to the generator.
public struct SchemaResource: Sendable {
    /// The stable identity used to resolve relative `$ref` paths.
    public let url: URL
    public let data: Data

    public init(data: Data, url: URL) {
        self.data = data
        self.url = url.isFileURL ? url.standardizedFileURL : url.absoluteURL
    }

    public init(contentsOf url: URL) throws {
        guard url.isFileURL else {
            throw GenerationError.invalidArguments(
                "schema file URL must use the file scheme: \(url.absoluteString)")
        }
        do {
            self.init(data: try Data(contentsOf: url), url: url)
        } catch {
            throw GenerationError.io(
                "failed reading schema '\(url.path(percentEncoded: false))': \(error)")
        }
    }
}
