import Foundation

enum DraftVersion: String, CaseIterable, Sendable {
    case draft7 = "draft-07"
    case draft2019_09 = "draft-2019-09"
    case draft2020_12 = "draft-2020-12"

    static func detect(from schemaValue: String?) throws -> DraftVersion {
        guard let schemaValue else { return .draft2020_12 }
        guard let url = URL(string: schemaValue),
            let scheme = url.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            let host = url.host?.lowercased(),
            url.user == nil,
            url.password == nil,
            url.port == nil,
            url.query == nil,
            url.fragment?.isEmpty != false
        else {
            throw GenerationError.schema("invalid $schema URI: '\(schemaValue)'")
        }

        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard host == "json-schema.org" else {
            throw unsupportedDialect(schemaValue)
        }

        switch path {
        case "draft-07/schema": return .draft7
        case "draft/2019-09/schema": return .draft2019_09
        case "draft/2020-12/schema": return .draft2020_12
        default: throw unsupportedDialect(schemaValue)
        }
    }

    private static func unsupportedDialect(_ value: String) -> GenerationError {
        GenerationError.schema(
            "unsupported JSONValue Schema dialect '\(value)'; supported dialects are draft-07, 2019-09, and 2020-12"
        )
    }
}

struct SchemaDocument {
    let url: URL
    let json: JSONValue
    let draft: DraftVersion
    let allowedKeywords: Set<String>
    var diagnostics: [GenerationDiagnostic] = []
}

struct ResolvedSchema {
    /// Physical input URL, retained for source diagnostics and generated naming.
    let documentURL: URL
    let json: JSONValue
    /// RFC 3986 base URI in effect for references inside `json`.
    let effectiveBaseURL: URL
    /// JSONValue Schema dialect in effect at the resolved schema location.
    let draft: DraftVersion
}
