public struct GenerationResult: Sendable {
    public let source: String
    public let diagnostics: [GenerationDiagnostic]

    public init(source: String, diagnostics: [GenerationDiagnostic]) {
        self.source = source
        self.diagnostics = diagnostics
    }
}
