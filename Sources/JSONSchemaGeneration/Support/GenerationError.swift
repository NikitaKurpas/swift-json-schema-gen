import Foundation

public enum GenerationError: Error, CustomStringConvertible, LocalizedError, Sendable {
    case invalidArguments(String)
    case io(String)
    case schema(String)
    case codegen(String)
    case diagnostics([GenerationDiagnostic])

    public var description: String {
        switch self {
        case .invalidArguments(let message):
            return "invalid arguments: \(message)"
        case .io(let message):
            return "io error: \(message)"
        case .schema(let message):
            return "schema error: \(message)"
        case .codegen(let message):
            return "codegen error: \(message)"
        case .diagnostics(let diagnostics):
            return diagnostics.map { diagnostic in
                let location = [diagnostic.sourceURL?.absoluteString, diagnostic.pointer].compactMap
                { $0 }.joined()
                let prefix = location.isEmpty ? "" : "\(location): "
                let code = diagnostic.code.map { "[\($0)] " } ?? ""
                return "\(prefix)\(diagnostic.severity.rawValue): \(code)\(diagnostic.message)"
            }.joined(separator: "\n")
        }
    }

    public var errorDescription: String? { description }
}
