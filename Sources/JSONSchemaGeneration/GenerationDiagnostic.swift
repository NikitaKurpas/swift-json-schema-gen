import Foundation

public struct GenerationDiagnostic: Codable, Equatable, Sendable {
    public enum Severity: String, Codable, Sendable {
        case warning
        case error
    }

    public let severity: Severity
    public let message: String
    public let sourceURL: URL?
    public let pointer: String?
    public let code: String?
    public let suggestion: String?
    public let keyword: String?
    public let dialect: String?

    public init(
        severity: Severity,
        message: String,
        sourceURL: URL? = nil,
        pointer: String? = nil,
        code: String? = nil,
        suggestion: String? = nil,
        keyword: String? = nil,
        dialect: String? = nil
    ) {
        self.severity = severity
        self.message = message
        self.sourceURL = sourceURL
        self.pointer = pointer
        self.code = code
        self.suggestion = suggestion
        self.keyword = keyword
        self.dialect = dialect
    }
}
