import ArgumentParser
import Foundation
import JSONSchemaGeneration

@main
struct SwiftJSONSchemaGenCLI {
    static func main() async {
        do {
            var command = try JSONSchemaGeneratorCommand.parse()
            try await command.run()
        } catch {
            if JSONSchemaGeneratorCommand.exitCode(for: error).isSuccess {
                JSONSchemaGeneratorCommand.exit(withError: error)
            }
            guard requestsJSONDiagnostics else {
                JSONSchemaGeneratorCommand.exit(withError: error)
            }

            let diagnostics: [GenerationDiagnostic]
            if case GenerationError.diagnostics(let typedDiagnostics) = error {
                diagnostics = typedDiagnostics
            } else {
                diagnostics = [
                    GenerationDiagnostic(
                        severity: .error,
                        message: error.localizedDescription,
                        code: "generation_failed"
                    )
                ]
            }
            if let data = try? JSONEncoder().encode(diagnostics) {
                FileHandle.standardError.write(data)
                FileHandle.standardError.write(Data("\n".utf8))
            }
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static var requestsJSONDiagnostics: Bool {
        let arguments = CommandLine.arguments.dropFirst()
        return arguments.enumerated().contains { index, value in
            value == "--diagnostics-format=json"
                || (value == "--diagnostics-format"
                    && arguments.dropFirst(index + 1).first == "json")
        }
    }
}
