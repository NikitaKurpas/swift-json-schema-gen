import Foundation

/// Generates Swift declarations without performing file-system writes.
public struct JSONSchemaGenerator: Sendable {
    public init() {}

    public func generate(
        resources: [SchemaResource],
        options: GenerationOptions = .init()
    ) throws -> GenerationResult {
        guard !resources.isEmpty else {
            throw GenerationError.invalidArguments("at least one schema resource is required")
        }
        let documents = try SchemaLoader().loadDocuments(resources: resources)
        let resolver = try RefResolver(documents: documents)
        var builder = TypeBuilder(documents: documents, resolver: resolver, options: options)
        let declarations = try builder.build()
        let source = try SwiftEmitter(options: options).emitFile(
            declarations: declarations,
            typeAliases: builder.topLevelDefinitionTypeAliases
        )
        let diagnostics = documents.values
            .flatMap(\.diagnostics)
            .sorted { lhs, rhs in
                let lhsLocation = (lhs.sourceURL?.absoluteString ?? "") + (lhs.pointer ?? "")
                let rhsLocation = (rhs.sourceURL?.absoluteString ?? "") + (rhs.pointer ?? "")
                return lhsLocation == rhsLocation
                    ? lhs.message < rhs.message : lhsLocation < rhsLocation
            }

        if options.warningsAsErrors {
            let promoted = diagnostics.filter { $0.severity == .warning }.map { diagnostic in
                GenerationDiagnostic(
                    severity: .error,
                    message: diagnostic.message,
                    sourceURL: diagnostic.sourceURL,
                    pointer: diagnostic.pointer,
                    code: diagnostic.code,
                    suggestion: diagnostic.suggestion,
                    keyword: diagnostic.keyword,
                    dialect: diagnostic.dialect
                )
            }
            if !promoted.isEmpty {
                throw GenerationError.diagnostics(promoted)
            }
        }

        return GenerationResult(source: source, diagnostics: diagnostics)
    }

    /// Loads schema files and delegates to the in-memory API.
    public func generate(
        schemaURLs: [URL],
        options: GenerationOptions = .init()
    ) throws -> GenerationResult {
        try generate(resources: schemaURLs.map(SchemaResource.init(contentsOf:)), options: options)
    }
}
