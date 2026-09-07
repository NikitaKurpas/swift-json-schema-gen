import Foundation

struct Vocabulary {
    let draft7Keywords: Set<String>
    let draft2019Keywords: Set<String>
    let draft2020Keywords: Set<String>

    static func load() throws -> Vocabulary {
        let annotations: Set<String> = [
            "$comment", "default", "deprecated", "description", "examples", "readOnly", "title",
            "writeOnly",
        ]
        let draft7 = try readKeywords(resource: "draft-07-schema").union(annotations)
        let core = try readKeywords(resource: "draft-2020-12-core")
        let applicator = try readKeywords(resource: "draft-2020-12-applicator")
        let validation = try readKeywords(resource: "draft-2020-12-validation")
        let modernAdditions: Set<String> = [
            "$anchor", "$defs", "$dynamicAnchor", "$dynamicRef", "$vocabulary",
            "contentEncoding", "contentMediaType", "contentSchema", "dependentRequired",
            "dependentSchemas", "definitions", "format", "maxContains", "minContains",
            "prefixItems", "unevaluatedItems", "unevaluatedProperties",
        ]
        let draft2020 = core.union(applicator).union(validation).union(annotations).union(
            modernAdditions)
        let draft2019 =
            draft2020
            .subtracting(["$dynamicAnchor", "$dynamicRef", "prefixItems"])
            .union(["$recursiveAnchor", "$recursiveRef", "additionalItems", "dependencies"])
        return Vocabulary(
            draft7Keywords: draft7,
            draft2019Keywords: draft2019,
            draft2020Keywords: draft2020
        )
    }

    func keywords(for draft: DraftVersion) -> Set<String> {
        switch draft {
        case .draft7:
            return draft7Keywords
        case .draft2019_09:
            return draft2019Keywords
        case .draft2020_12:
            return draft2020Keywords
        }
    }

    func isKnownVocabulary(_ uri: String, for draft: DraftVersion) -> Bool {
        let prefix: String
        switch draft {
        case .draft7:
            return false
        case .draft2019_09:
            prefix = "https://json-schema.org/draft/2019-09/vocab/"
        case .draft2020_12:
            prefix = "https://json-schema.org/draft/2020-12/vocab/"
        }
        guard uri.hasPrefix(prefix) else { return false }
        let name = String(uri.dropFirst(prefix.count))
        return [
            "applicator", "content", "core", "format", "format-annotation", "meta-data",
            "unevaluated", "validation",
        ].contains(name)
    }

    var allKnownKeywords: Set<String> {
        draft7Keywords.union(draft2019Keywords).union(draft2020Keywords)
    }

    func fullySupportsRequiredVocabulary(_ uri: String, for draft: DraftVersion) -> Bool {
        guard isKnownVocabulary(uri, for: draft) else { return false }
        return uri.hasSuffix("/meta-data") || uri.hasSuffix("/format-annotation")
            || uri.hasSuffix("/content")
    }

    private static func readKeywords(resource: String) throws -> Set<String> {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "json") else {
            throw GenerationError.schema("meta-schema resource not found: \(resource).json")
        }
        let data = try Data(contentsOf: url)
        let json = try JSONValue(data: data)
        let keys = json["properties"].dictionaryValue.keys
        if keys.isEmpty {
            throw GenerationError.schema("meta-schema '\(resource)' has no properties block")
        }
        return Set(keys)
    }
}
