import Foundation

enum TestSupport {
    static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-json-schema-gen-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func fixture(named name: String) throws -> URL {
        guard
            let url = Bundle.module.url(
                forResource: name, withExtension: nil, subdirectory: "Fixtures")
        else {
            throw TestSupportError("Missing test fixture: \(name)")
        }
        return url
    }

    @discardableResult
    static func run(
        executable: URL,
        arguments: [String]
    ) throws -> (stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let captureDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: captureDirectory) }
        let stdoutURL = captureDirectory.appendingPathComponent("stdout")
        let stderrURL = captureDirectory.appendingPathComponent("stderr")
        _ = FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        _ = FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        try process.run()
        let deadline = Date().addingTimeInterval(60)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw TestProcessError(
                command: ([executable.path] + arguments).joined(separator: " "),
                status: process.terminationStatus,
                stderr: "process exceeded the 60 second test timeout"
            )
        }
        try stdoutHandle.close()
        try stderrHandle.close()

        let stdout = String(data: try Data(contentsOf: stdoutURL), encoding: .utf8) ?? ""
        let stderr = String(data: try Data(contentsOf: stderrURL), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw TestProcessError(
                command: ([executable.path] + arguments).joined(separator: " "),
                status: process.terminationStatus,
                stderr: stderr
            )
        }
        return (stdout, stderr)
    }

    static func compileSwift(
        sources: [URL],
        output: URL,
        additionalArguments: [String] = []
    ) throws {
        try run(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [
                "swiftc",
                "-swift-version", "6",
                "-strict-memory-safety",
                "-warnings-as-errors",
            ] + additionalArguments + sources.map(\.path) + ["-o", output.path]
        )
    }

}

struct TestSupportError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

struct TestProcessError: Error, CustomStringConvertible {
    let command: String
    let status: Int32
    let stderr: String

    var description: String {
        "Process exited with status \(status): \(command)\n\(stderr)"
    }
}
