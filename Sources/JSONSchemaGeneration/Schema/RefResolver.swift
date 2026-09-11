import Foundation

struct RefResolver {
    private struct Resource {
        let documentURL: URL
        let canonicalURL: URL
        let json: JSONValue
        let draft: DraftVersion
    }

    private struct IndexedTarget {
        let resource: Resource
        let json: JSONValue
        let effectiveBaseURL: URL
        let draft: DraftVersion
    }

    private var resources: [String: Resource] = [:]
    private var anchors: [String: IndexedTarget] = [:]

    init(documents: [URL: SchemaDocument]) throws {
        for document in documents.values.sorted(by: {
            $0.url.absoluteString < $1.url.absoluteString
        }) {
            try index(document)
        }
    }

    func resolve(ref: String, from baseURL: URL) throws -> ResolvedSchema {
        guard let absoluteReference = URL(string: ref, relativeTo: baseURL)?.absoluteURL else {
            throw GenerationError.schema(
                "invalid $ref URI-reference '\(ref)' relative to '\(baseURL.absoluteString)'")
        }

        let resourceURL = try removingFragment(from: absoluteReference)
        guard let resource = resources[resourceKey(resourceURL)] else {
            throw missingResourceError(resourceURL, reference: ref)
        }

        guard
            let encodedFragment = URLComponents(
                url: absoluteReference, resolvingAgainstBaseURL: true)?.percentEncodedFragment,
            !encodedFragment.isEmpty
        else {
            return ResolvedSchema(
                documentURL: resource.documentURL,
                json: resource.json,
                effectiveBaseURL: resource.canonicalURL,
                draft: resource.draft
            )
        }

        guard let fragment = encodedFragment.removingPercentEncoding else {
            throw GenerationError.schema("invalid percent encoding in $ref fragment '\(ref)'")
        }

        if fragment.first != "/" {
            let key = anchorKey(resourceURL: resourceURL, name: fragment)
            guard let target = anchors[key] else {
                throw GenerationError.schema(
                    "unresolved schema anchor '#\(fragment)' in supplied resource '\(resourceURL.absoluteString)' (from $ref '\(ref)')"
                )
            }
            return ResolvedSchema(
                documentURL: target.resource.documentURL,
                json: target.json,
                effectiveBaseURL: target.effectiveBaseURL,
                draft: target.draft
            )
        }

        let target = try resource.json.resolvingJSONPointer(fragment, reference: ref)
        guard target.type == .dictionary || target.type == .bool else {
            throw GenerationError.schema(
                "$ref '\(ref)' resolves to a JSONValue value that is not an object or boolean schema"
            )
        }
        let context = try effectiveContextAlongPointer(
            fragment,
            resource: resource,
            reference: ref
        )
        return ResolvedSchema(
            documentURL: resource.documentURL,
            json: target,
            effectiveBaseURL: context.baseURL,
            draft: context.draft
        )
    }

    /// Applies a schema object's `$id` to the current RFC 3986 resolution scope.
    func effectiveBaseURL(for schema: JSONValue, from baseURL: URL) throws -> URL {
        guard let identifier = schema["$id"].string else { return baseURL }
        guard let resolved = URL(string: identifier, relativeTo: baseURL)?.absoluteURL else {
            throw GenerationError.schema(
                "invalid $id URI-reference '\(identifier)' relative to '\(baseURL.absoluteString)'")
        }
        return try removingFragment(from: resolved)
    }

    private mutating func index(_ document: SchemaDocument) throws {
        let retrievalURL = canonicalized(document.url)
        let rootCanonicalURL = try effectiveBaseURL(for: document.json, from: retrievalURL)
        let root = Resource(
            documentURL: retrievalURL, canonicalURL: rootCanonicalURL, json: document.json,
            draft: document.draft)
        try register(resource: root, as: retrievalURL)
        try register(resource: root, as: rootCanonicalURL)
        try registerIdentifiers(
            in: document.json,
            resource: root,
            baseURL: retrievalURL,
            draft: document.draft,
            pointer: ""
        )
    }

    private mutating func registerIdentifiers(
        in schema: JSONValue,
        resource inheritedResource: Resource,
        baseURL inheritedBaseURL: URL,
        draft: DraftVersion,
        pointer: String
    ) throws {
        guard schema.type == .dictionary else { return }
        let currentDraft = try DraftVersion.detect(
            from: schema["$schema"].string ?? draft.schemaURI)

        var resource = inheritedResource
        var baseURL = inheritedBaseURL
        if let identifier = schema["$id"].string {
            guard
                let identifierURL = URL(string: identifier, relativeTo: inheritedBaseURL)?
                    .absoluteURL
            else {
                throw GenerationError.schema(
                    "invalid $id URI-reference '\(identifier)' at #\(pointer) in '\(inheritedResource.documentURL.absoluteString)'"
                )
            }
            let identifierBase = try removingFragment(from: identifierURL)
            let encodedFragment = URLComponents(url: identifierURL, resolvingAgainstBaseURL: true)?
                .percentEncodedFragment

            baseURL = identifierBase
            if pointer.isEmpty {
                resource = Resource(
                    documentURL: resource.documentURL, canonicalURL: identifierBase, json: schema,
                    draft: currentDraft)
            } else if encodedFragment?.isEmpty ?? true
                || (currentDraft == .draft7 && identifierBase != inheritedBaseURL)
            {
                resource = Resource(
                    documentURL: resource.documentURL, canonicalURL: identifierBase, json: schema,
                    draft: currentDraft)
                try register(resource: resource, as: identifierBase)
            }

            if currentDraft == .draft7,
                let encodedFragment,
                !encodedFragment.isEmpty,
                !encodedFragment.hasPrefix("/")
            {
                try registerAnchor(
                    resourceURL: identifierBase,
                    name: encodedFragment.removingPercentEncoding ?? encodedFragment,
                    target: IndexedTarget(
                        resource: resource,
                        json: schema,
                        effectiveBaseURL: identifierBase,
                        draft: currentDraft
                    )
                )
            }
        }

        if currentDraft != .draft7, let anchor = schema["$anchor"].string {
            guard isValidAnchor(anchor) else {
                throw GenerationError.schema(
                    "invalid $anchor '\(anchor)' at #\(pointer) in '\(resource.documentURL.absoluteString)'"
                )
            }
            try registerAnchor(
                resourceURL: resource.canonicalURL,
                name: anchor,
                target: IndexedTarget(
                    resource: resource,
                    json: schema,
                    effectiveBaseURL: baseURL,
                    draft: currentDraft
                )
            )
        }

        for child in schemaChildren(of: schema, draft: currentDraft, parentPointer: pointer) {
            try registerIdentifiers(
                in: child.schema,
                resource: resource,
                baseURL: baseURL,
                draft: currentDraft,
                pointer: child.pointer
            )
        }
    }

    private mutating func register(resource: Resource, as url: URL) throws {
        let key = resourceKey(url)
        if let existing = resources[key],
            existing.documentURL != resource.documentURL
                || existing.json != resource.json
        {
            throw GenerationError.schema(
                "duplicate schema resource identifier '\(url.absoluteString)' in '\(existing.documentURL.absoluteString)' and '\(resource.documentURL.absoluteString)'"
            )
        }
        resources[key] = resource
    }

    private mutating func registerAnchor(resourceURL: URL, name: String, target: IndexedTarget)
        throws
    {
        let key = anchorKey(resourceURL: resourceURL, name: name)
        if anchors[key] != nil {
            throw GenerationError.schema(
                "duplicate schema anchor '\(key)' in '\(target.resource.documentURL.absoluteString)'"
            )
        }
        anchors[key] = target
    }

    private func effectiveContextAlongPointer(
        _ pointer: String,
        resource: Resource,
        reference: String
    ) throws -> (baseURL: URL, draft: DraftVersion) {
        var value = resource.json
        var baseURL = resource.canonicalURL
        var draft = resource.draft
        var kind = SchemaLocationKind.schema
        for token in try decodedJSONPointerTokens(pointer, reference: reference) {
            let nextKind: SchemaLocationKind
            switch kind {
            case .schema:
                nextKind = childLocationKind(keyword: token, value: value[token], draft: draft)
            case .schemaMap:
                nextKind = .schema
            case .definitionMap:
                nextKind = isLegacyDefinitionNamespace(value[token]) ? .definitionMap : .schema
            case .schemaArray:
                nextKind = .schema
            case .other:
                nextKind = .other
            }

            if value.type == .array, let index = Int(token) {
                value = value.arrayValue[index]
            } else {
                value = value.dictionaryValue[token] ?? .null
            }
            kind = nextKind
            if kind == .schema {
                baseURL = try effectiveBaseURL(for: value, from: baseURL)
                draft = try DraftVersion.detect(from: value["$schema"].string ?? draft.schemaURI)
            }
        }
        guard kind == .schema else {
            throw GenerationError.schema("$ref '\(reference)' resolves outside a schema location")
        }
        return (baseURL, draft)
    }

    private func missingResourceError(_ resourceURL: URL, reference: String) -> GenerationError {
        if resourceURL.isFileURL {
            return GenerationError.schema(
                "referenced schema resource was not supplied: '\(resourceURL.path(percentEncoded: false))' (from $ref '\(reference)')"
            )
        }
        return GenerationError.schema(
            "referenced schema resource was not supplied for offline generation: '\(resourceURL.absoluteString)' (from $ref '\(reference)'); pass it as an input resource"
        )
    }
}

private enum SchemaLocationKind {
    case schema
    case schemaMap
    case definitionMap
    case schemaArray
    case other
}

private func childLocationKind(keyword: String, value: JSONValue, draft: DraftVersion)
    -> SchemaLocationKind
{
    var singleSchemaKeywords: Set<String> = [
        "additionalProperties", "contains", "else", "if", "not", "propertyNames", "then",
    ]
    if draft != .draft2020_12 { singleSchemaKeywords.insert("additionalItems") }
    if draft != .draft7 {
        singleSchemaKeywords.formUnion([
            "contentSchema", "unevaluatedItems", "unevaluatedProperties",
        ])
    }
    if singleSchemaKeywords.contains(keyword) { return .schema }
    if keyword == "definitions" || (draft != .draft7 && keyword == "$defs") {
        return .definitionMap
    }
    if ["patternProperties", "properties"].contains(keyword) { return .schemaMap }
    if draft != .draft7 && keyword == "dependentSchemas" { return .schemaMap }
    if ["allOf", "anyOf", "oneOf"].contains(keyword) { return .schemaArray }
    if draft == .draft2020_12 && keyword == "prefixItems" { return .schemaArray }
    if keyword == "items" {
        return value.type == .array ? .schemaArray : .schema
    }
    if draft != .draft2020_12 && keyword == "dependencies" { return .schemaMap }
    return .other
}

extension DraftVersion {
    var schemaURI: String {
        switch self {
        case .draft7: return "http://json-schema.org/draft-07/schema#"
        case .draft2019_09: return "https://json-schema.org/draft/2019-09/schema"
        case .draft2020_12: return "https://json-schema.org/draft/2020-12/schema"
        }
    }
}

struct SchemaChild {
    let schema: JSONValue
    let pointer: String
}

func schemaChildren(of schema: JSONValue, draft: DraftVersion, parentPointer: String)
    -> [SchemaChild]
{
    var singleKeywords = [
        "additionalProperties", "contains", "else", "if", "not", "propertyNames", "then",
    ]
    if draft != .draft2020_12 { singleKeywords.append("additionalItems") }
    if draft != .draft7 {
        singleKeywords += ["contentSchema", "unevaluatedItems", "unevaluatedProperties"]
    }
    var mapKeywords = ["definitions", "patternProperties", "properties"]
    if draft != .draft7 {
        mapKeywords += ["$defs", "dependentSchemas"]
    }
    var arrayKeywords = ["allOf", "anyOf", "oneOf"]
    if draft == .draft2020_12 {
        arrayKeywords.append("prefixItems")
    }
    var children: [SchemaChild] = []

    for keyword in singleKeywords
    where schema[keyword].type == .dictionary || schema[keyword].type == .bool {
        children.append(
            SchemaChild(schema: schema[keyword], pointer: appendPointer(parentPointer, keyword)))
    }
    if let items = schema["items"].array, draft != .draft2020_12 {
        for (index, child) in items.enumerated() {
            children.append(
                SchemaChild(
                    schema: child,
                    pointer: appendPointer(appendPointer(parentPointer, "items"), String(index))))
        }
    } else if schema["items"].type == .dictionary || schema["items"].type == .bool {
        children.append(
            SchemaChild(schema: schema["items"], pointer: appendPointer(parentPointer, "items")))
    }
    for keyword in mapKeywords {
        for (name, child) in schema[keyword].dictionaryValue {
            let childPointer = appendPointer(appendPointer(parentPointer, keyword), name)
            if (keyword == "definitions" || keyword == "$defs")
                && isLegacyDefinitionNamespace(child)
            {
                children += legacyDefinitionChildren(in: child, pointer: childPointer)
            } else {
                children.append(SchemaChild(schema: child, pointer: childPointer))
            }
        }
    }
    for keyword in arrayKeywords {
        for (index, child) in schema[keyword].arrayValue.enumerated() {
            children.append(
                SchemaChild(
                    schema: child,
                    pointer: appendPointer(appendPointer(parentPointer, keyword), String(index))))
        }
    }
    if draft != .draft2020_12 {
        for (name, child) in schema["dependencies"].dictionaryValue
        where child.type == .dictionary || child.type == .bool {
            children.append(
                SchemaChild(
                    schema: child,
                    pointer: appendPointer(appendPointer(parentPointer, "dependencies"), name)))
        }
    }
    return children
}

private func legacyDefinitionChildren(in namespace: JSONValue, pointer: String) -> [SchemaChild] {
    namespace.dictionaryValue.flatMap { name, child -> [SchemaChild] in
        let childPointer = appendPointer(pointer, name)
        if isLegacyDefinitionNamespace(child) {
            return legacyDefinitionChildren(in: child, pointer: childPointer)
        }
        return [SchemaChild(schema: child, pointer: childPointer)]
    }
}

func isLegacyDefinitionNamespace(_ value: JSONValue) -> Bool {
    guard let entries = value.dictionary, !entries.isEmpty else { return false }
    let schemaKeywords: Set<String> = [
        "$anchor", "$comment", "$defs", "$dynamicAnchor", "$dynamicRef", "$id", "$ref",
        "$recursiveAnchor", "$recursiveRef", "$schema", "$vocabulary", "additionalItems",
        "additionalProperties", "allOf", "anyOf", "const", "contains", "contentEncoding",
        "contentMediaType", "contentSchema", "default", "definitions", "dependentRequired",
        "dependentSchemas", "deprecated", "description", "else", "enum", "examples",
        "exclusiveMaximum", "exclusiveMinimum", "format", "if", "items", "maximum", "maxContains",
        "maxItems", "maxLength", "maxProperties", "minimum", "minContains", "minItems", "minLength",
        "minProperties", "multipleOf", "not", "oneOf", "pattern", "patternProperties",
        "prefixItems",
        "properties", "propertyNames", "readOnly", "required", "then", "title", "type",
        "unevaluatedItems", "unevaluatedProperties", "uniqueItems", "writeOnly",
    ]
    guard entries.keys.allSatisfy({ !schemaKeywords.contains($0) }),
        entries.values.allSatisfy({ $0.type == .dictionary || $0.type == .bool })
    else { return false }

    return entries.contains { name, child in
        name.isTypeLikeIdentifier || child.type == .bool || isLegacyDefinitionNamespace(child)
    }
}

func appendPointer(_ pointer: String, _ token: String) -> String {
    let escaped = token.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(
        of: "/", with: "~1")
    return pointer + "/" + escaped
}

private func removingFragment(from url: URL) throws -> URL {
    guard var components = URLComponents(url: url.absoluteURL, resolvingAgainstBaseURL: true) else {
        throw GenerationError.schema("invalid schema URI '\(url.absoluteString)'")
    }
    components.fragment = nil
    guard let result = components.url else {
        throw GenerationError.schema("invalid schema URI '\(url.absoluteString)'")
    }
    return canonicalized(result)
}

private func canonicalized(_ url: URL) -> URL {
    url.isFileURL ? url.standardizedFileURL : url.absoluteURL
}

private func resourceKey(_ url: URL) -> String {
    canonicalized(url).absoluteString
}

private func anchorKey(resourceURL: URL, name: String) -> String {
    resourceKey(resourceURL) + "#" + name
}

private func isValidAnchor(_ anchor: String) -> Bool {
    guard let first = anchor.first, first.isASCII, first.isLetter else { return false }
    return anchor.dropFirst().allSatisfy { character in
        character.isASCII
            && (character.isLetter || character.isNumber || "-_:.".contains(character))
    }
}
