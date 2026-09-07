import Foundation

/// File-system adapter kept separate from the pure generation API.
public struct GeneratedSourceWriter: Sendable {
    public init() {}

    public func write(_ result: GenerationResult, to outputURL: URL) throws {
        let fileManager = FileManager.default
        let outputURL = outputURL.standardizedFileURL
        let parent = outputURL.deletingLastPathComponent()

        do {
            let data = Data(result.source.utf8)
            if fileManager.fileExists(atPath: outputURL.path(percentEncoded: false)),
                try Data(contentsOf: outputURL) == data
            {
                return
            }
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            try data.write(to: outputURL, options: .atomic)
        } catch {
            throw GenerationError.io(
                "failed to write output file '\(outputURL.path(percentEncoded: false))': \(error)")
        }
    }
}
