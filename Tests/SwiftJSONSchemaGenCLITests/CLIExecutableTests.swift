import Foundation
import Testing

struct CLIExecutableTests {
    @Test(arguments: ["--help", "--version"])
    func cleanExitRemainsSuccessfulWithJSONDiagnostics(_ cleanExitArgument: String) throws {
        let result = try runCLI([
            cleanExitArgument,
            "--diagnostics-format", "json",
        ])

        #expect(result.status == 0)
        #expect(result.stderr.isEmpty)
        if cleanExitArgument == "--help" {
            #expect(result.stdout.contains("USAGE: SwiftJSONSchemaGen"))
        } else {
            #expect(result.stdout == "0.1.0\n")
        }
    }

    private func runCLI(_ arguments: [String]) throws -> (
        status: Int32, stdout: String, stderr: String
    ) {
        let process = Process()
        process.executableURL = try cliExecutableURL()
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private func cliExecutableURL() throws -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidate = packageRoot.appending(path: ".build/debug/SwiftJSONSchemaGen")
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        throw CLIExecutableTestError.notFound
    }
}

private enum CLIExecutableTestError: Error {
    case notFound
}
