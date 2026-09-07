import Foundation

struct SchemaLoader {
    func loadDocuments(at urls: [URL]) throws -> [URL: SchemaDocument] {
        try loadDocuments(resources: urls.map(SchemaResource.init(contentsOf:)))
    }

    func loadDocuments(resources: [SchemaResource]) throws -> [URL: SchemaDocument] {
        let vocabulary = try Vocabulary.load()
        var documents: [URL: SchemaDocument] = [:]
        for resource in resources {
            let url = canonicalizedSchemaURL(resource.url)
            let json: JSONValue
            do {
                json = try JSONValue(data: resource.data)
            } catch {
                throw GenerationError.schema(
                    "invalid JSONValue schema '\(url.absoluteString)': \(error)")
            }

            guard json.type == .dictionary || json.type == .bool else {
                throw GenerationError.schema(
                    "schema resource '\(url.absoluteString)' must contain a JSONValue object or boolean"
                )
            }
            guard documents[url] == nil else {
                throw GenerationError.schema(
                    "duplicate input schema resource URL '\(url.absoluteString)'")
            }

            let draft = try DraftVersion.detect(from: json["$schema"].string)
            let diagnostics = try inspectSchema(
                json, sourceURL: url, draft: draft, vocabulary: vocabulary, pointer: "")
            documents[url] = SchemaDocument(
                url: url,
                json: json,
                draft: draft,
                allowedKeywords: vocabulary.keywords(for: draft),
                diagnostics: diagnostics
            )
        }
        return documents
    }

    private func inspectSchema(
        _ schema: JSONValue,
        sourceURL: URL,
        draft inheritedDraft: DraftVersion,
        vocabulary: Vocabulary,
        pointer: String
    ) throws -> [GenerationDiagnostic] {
        guard schema.type == .dictionary else { return [] }
        if schema["$schema"].exists(), schema["$schema"].string == nil {
            throw malformedKeyword(
                "$schema", expected: "a URI string", pointer: pointer, sourceURL: sourceURL)
        }
        let draft = try DraftVersion.detect(
            from: schema["$schema"].string ?? inheritedDraft.schemaURI)
        try validateKeywordShapes(in: schema, draft: draft, pointer: pointer, sourceURL: sourceURL)

        var diagnostics: [GenerationDiagnostic] = []
        if schema["$vocabulary"].exists() {
            guard draft != .draft7 else {
                throw GenerationError.schema(
                    "$vocabulary is not valid in draft-07 at #\(appendPointer(pointer, "$vocabulary")) in '\(sourceURL.absoluteString)'"
                )
            }
            guard let declarations = schema["$vocabulary"].dictionary else {
                throw malformedKeyword(
                    "$vocabulary", expected: "an object of vocabulary URI to boolean entries",
                    pointer: pointer, sourceURL: sourceURL)
            }
            for (uri, requirement) in declarations.sorted(by: { $0.key < $1.key }) {
                guard let required = requirement.bool else {
                    throw GenerationError.schema(
                        "$vocabulary value for '\(uri)' must be a boolean at #\(appendPointer(pointer, "$vocabulary"))"
                    )
                }
                if required && !vocabulary.fullySupportsRequiredVocabulary(uri, for: draft) {
                    let detail =
                        vocabulary.isKnownVocabulary(uri, for: draft)
                        ? "is only partially implemented" : "is not recognized"
                    throw GenerationError.schema(
                        "required JSONValue Schema vocabulary \(detail): '\(uri)' at #\(appendPointer(pointer, "$vocabulary"))"
                    )
                }
                if !required && !vocabulary.isKnownVocabulary(uri, for: draft) {
                    diagnostics.append(
                        .init(
                            severity: .warning,
                            message:
                                "Optional JSONValue Schema vocabulary is not recognized and will be ignored: \(uri)",
                            sourceURL: sourceURL,
                            pointer: appendPointer(appendPointer(pointer, "$vocabulary"), uri),
                            code: "optional_vocabulary",
                            suggestion:
                                "Remove the declaration or provide a schema that does not rely on this vocabulary",
                            keyword: "$vocabulary",
                            dialect: draft.rawValue
                        ))
                }
            }
        }

        let allowedKeywords = vocabulary.keywords(for: draft)
        for keyword in schema.dictionaryValue.keys.sorted()
        where !allowedKeywords.contains(keyword) && !keyword.hasPrefix("x-") {
            let knownInAnotherDialect = vocabulary.allKnownKeywords.contains(keyword)
            diagnostics.append(
                .init(
                    severity: .warning,
                    message: knownInAnotherDialect
                        ? "Keyword '\(keyword)' does not belong to \(draft.rawValue) and will be ignored"
                        : "Unknown JSONValue Schema keyword '\(keyword)' will be ignored",
                    sourceURL: sourceURL,
                    pointer: appendPointer(pointer, keyword),
                    code: knownInAnotherDialect ? "wrong_dialect_keyword" : "unknown_keyword",
                    suggestion: knownInAnotherDialect
                        ? "Use the keyword defined for \(draft.rawValue), or change the declared $schema dialect"
                        : "Prefix intentional extension annotations with 'x-' to silence this diagnostic",
                    keyword: keyword,
                    dialect: draft.rawValue
                ))
        }

        for keyword in unsupportedKeywords(in: schema, draft: draft).intersection(allowedKeywords)
            .sorted()
        {
            diagnostics.append(
                .init(
                    severity: .warning,
                    message:
                        "Keyword '\(keyword)' is recognized by \(draft.rawValue), but generated Codable types do not enforce its semantics",
                    sourceURL: sourceURL,
                    pointer: appendPointer(pointer, keyword),
                    code: "unsupported_keyword",
                    suggestion:
                        "Remove this keyword, model the constraint in Swift, or enable warnings-as-errors to reject semantic loss",
                    keyword: keyword,
                    dialect: draft.rawValue
                ))
        }

        if let inferredType = inferredStructuralType(in: schema, draft: draft) {
            diagnostics.append(
                .init(
                    severity: .warning,
                    message:
                        "Schema has no explicit type, but generation infers '\(inferredType)'; JSONValue Schema also accepts values of other types here",
                    sourceURL: sourceURL,
                    pointer: pointer,
                    code: "inferred_type",
                    suggestion:
                        "Add \"type\": \"\(inferredType)\" to make the generated Swift type match the schema",
                    keyword: "type",
                    dialect: draft.rawValue
                ))
        }

        for child in schemaChildren(of: schema, draft: draft, parentPointer: pointer) {
            diagnostics += try inspectSchema(
                child.schema, sourceURL: sourceURL, draft: draft, vocabulary: vocabulary,
                pointer: child.pointer)
        }
        return diagnostics
    }

    private func inferredStructuralType(in schema: JSONValue, draft: DraftVersion) -> String? {
        guard !schema["type"].exists(),
            !schema["$ref"].exists(),
            !schema["allOf"].exists(),
            !schema["anyOf"].exists(),
            !schema["oneOf"].exists(),
            !schema["enum"].exists(),
            !schema["const"].exists()
        else { return nil }

        if schema["properties"].exists() || schema["required"].exists() { return "object" }
        if schema["items"].exists() || (draft == .draft2020_12 && schema["prefixItems"].exists()) {
            return "array"
        }
        return nil
    }

    private func validateKeywordShapes(
        in schema: JSONValue,
        draft: DraftVersion,
        pointer: String,
        sourceURL: URL
    ) throws {
        let dictionary = schema.dictionaryValue
        var stringKeywords = ["$id", "$ref", "description", "format", "pattern", "title"]
        if draft != .draft7 { stringKeywords += ["$anchor", "$recursiveRef"] }
        if draft == .draft2020_12 { stringKeywords += ["$dynamicAnchor", "$dynamicRef"] }
        for keyword in stringKeywords
        where dictionary[keyword] != nil && schema[keyword].string == nil {
            throw malformedKeyword(
                keyword, expected: "a string", pointer: pointer, sourceURL: sourceURL)
        }

        if let identifier = schema["$id"].string {
            guard let url = URL(string: identifier) else {
                throw malformedKeyword(
                    "$id", expected: "a valid URI-reference", pointer: pointer, sourceURL: sourceURL
                )
            }
            if draft != .draft7, url.fragment?.isEmpty == false {
                throw malformedKeyword(
                    "$id", expected: "a URI-reference without a fragment in \(draft.rawValue)",
                    pointer: pointer, sourceURL: sourceURL)
            }
        }
        var anchorKeywords = draft == .draft7 ? [] : ["$anchor"]
        if draft == .draft2020_12 { anchorKeywords.append("$dynamicAnchor") }
        for keyword in anchorKeywords {
            if let anchor = schema[keyword].string, !isValidSchemaAnchor(anchor) {
                throw malformedKeyword(
                    keyword, expected: "a plain-name anchor beginning with an ASCII letter",
                    pointer: pointer, sourceURL: sourceURL)
            }
        }

        var schemaMapKeywords = ["definitions", "patternProperties", "properties"]
        if draft != .draft7 { schemaMapKeywords += ["$defs", "dependentSchemas"] }
        for keyword in schemaMapKeywords
        where dictionary[keyword] != nil && schema[keyword].dictionary == nil {
            throw malformedKeyword(
                keyword, expected: "an object containing schemas", pointer: pointer,
                sourceURL: sourceURL)
        }
        for keyword in schemaMapKeywords {
            if let entries = schema[keyword].dictionary {
                for (name, child) in entries where child.type != .dictionary && child.type != .bool
                {
                    let childPointer = appendPointer(appendPointer(pointer, keyword), name)
                    throw GenerationError.schema(
                        "malformed schema at #\(childPointer) in '\(sourceURL.absoluteString)': expected an object or boolean schema"
                    )
                }
            }
        }
        var schemaArrayKeywords = ["allOf", "anyOf", "oneOf"]
        if draft == .draft2020_12 { schemaArrayKeywords.append("prefixItems") }
        for keyword in schemaArrayKeywords where dictionary[keyword] != nil {
            guard let values = schema[keyword].array, !values.isEmpty,
                values.allSatisfy({ $0.type == .dictionary || $0.type == .bool })
            else {
                throw malformedKeyword(
                    keyword, expected: "a non-empty array of object or boolean schemas",
                    pointer: pointer, sourceURL: sourceURL)
            }
        }

        if dictionary["required"] != nil {
            guard let required = schema["required"].array,
                required.allSatisfy({ $0.string != nil }),
                Set(required.compactMap(\.string)).count == required.count
            else {
                throw malformedKeyword(
                    "required", expected: "an array of unique strings", pointer: pointer,
                    sourceURL: sourceURL)
            }
        }
        if dictionary["enum"] != nil {
            guard let values = schema["enum"].array, !values.isEmpty,
                Set(values.compactMap(canonicalJSONString)).count == values.count
            else {
                throw malformedKeyword(
                    "enum", expected: "a non-empty array of unique JSONValue values",
                    pointer: pointer,
                    sourceURL: sourceURL)
            }
        }

        if dictionary["type"] != nil {
            let validTypes: Set<String> = [
                "array", "boolean", "integer", "null", "number", "object", "string",
            ]
            if let type = schema["type"].string {
                guard validTypes.contains(type) else {
                    throw malformedKeyword(
                        "type", expected: "a JSONValue Schema primitive type name",
                        pointer: pointer,
                        sourceURL: sourceURL)
                }
            } else if let types = schema["type"].array {
                let values = types.compactMap(\.string)
                guard values.count == types.count, !values.isEmpty,
                    Set(values).count == values.count,
                    values.allSatisfy(validTypes.contains)
                else {
                    throw malformedKeyword(
                        "type",
                        expected:
                            "a non-empty array of unique JSONValue Schema primitive type names",
                        pointer: pointer, sourceURL: sourceURL)
                }
            } else {
                throw malformedKeyword(
                    "type", expected: "a string or array of unique strings", pointer: pointer,
                    sourceURL: sourceURL)
            }
        }

        if dictionary["items"] != nil {
            let items = schema["items"]
            let schemaForm = items.type == .dictionary || items.type == .bool
            let tupleForm = draft != .draft2020_12 && items.array?.isEmpty == false
            guard schemaForm || tupleForm else {
                throw malformedKeyword(
                    "items",
                    expected: draft == .draft7
                        ? "a schema or non-empty schema array" : "an object or boolean schema",
                    pointer: pointer, sourceURL: sourceURL)
            }
        }
        var schemaValueKeywords = [
            "additionalProperties", "contains", "else", "if", "not", "propertyNames", "then",
        ]
        if draft != .draft2020_12 { schemaValueKeywords.append("additionalItems") }
        if draft != .draft7 {
            schemaValueKeywords += ["contentSchema", "unevaluatedItems", "unevaluatedProperties"]
        }
        for keyword in schemaValueKeywords
        where dictionary[keyword] != nil && schema[keyword].type != .dictionary
            && schema[keyword].type != .bool
        {
            throw malformedKeyword(
                keyword, expected: "an object or boolean schema", pointer: pointer,
                sourceURL: sourceURL)
        }

        for keyword in [
            "maxContains", "maxItems", "maxLength", "maxProperties", "minContains", "minItems",
            "minLength", "minProperties",
        ]
        where dictionary[keyword] != nil {
            guard let value = schema[keyword].int, value >= 0 else {
                throw malformedKeyword(
                    keyword, expected: "a non-negative integer", pointer: pointer,
                    sourceURL: sourceURL)
            }
        }
        for keyword in ["exclusiveMaximum", "exclusiveMinimum", "maximum", "minimum", "multipleOf"]
        where dictionary[keyword] != nil && schema[keyword].number == nil {
            throw malformedKeyword(
                keyword, expected: "a number", pointer: pointer, sourceURL: sourceURL)
        }
        if let multipleOf = schema["multipleOf"].double, multipleOf <= 0 {
            throw malformedKeyword(
                "multipleOf", expected: "a number greater than zero", pointer: pointer,
                sourceURL: sourceURL)
        }
        var booleanKeywords = ["readOnly", "uniqueItems", "writeOnly"]
        if draft == .draft2019_09 { booleanKeywords.append("$recursiveAnchor") }
        for keyword in booleanKeywords
        where dictionary[keyword] != nil && schema[keyword].bool == nil {
            throw malformedKeyword(
                keyword, expected: "a boolean", pointer: pointer, sourceURL: sourceURL)
        }

        if draft != .draft2020_12, dictionary["dependencies"] != nil {
            guard let dependencies = schema["dependencies"].dictionary else {
                throw malformedKeyword(
                    "dependencies", expected: "an object", pointer: pointer, sourceURL: sourceURL)
            }
            for (name, dependency) in dependencies {
                let isSchema = dependency.type == .dictionary || dependency.type == .bool
                let strings = dependency.array?.compactMap(\.string)
                let isUniqueStringArray =
                    strings.map { !$0.isEmpty && Set($0).count == $0.count } ?? false
                if !isSchema && !isUniqueStringArray {
                    let location = appendPointer(appendPointer(pointer, "dependencies"), name)
                    throw GenerationError.schema(
                        "malformed dependency at #\(location): expected a schema or a non-empty array of unique strings"
                    )
                }
            }
        }
        if draft != .draft7, dictionary["dependentRequired"] != nil {
            guard let dependencies = schema["dependentRequired"].dictionary else {
                throw malformedKeyword(
                    "dependentRequired", expected: "an object of non-empty unique string arrays",
                    pointer: pointer, sourceURL: sourceURL)
            }
            for (name, dependency) in dependencies {
                let strings = dependency.array?.compactMap(\.string)
                guard let strings, !strings.isEmpty, strings.count == dependency.array?.count,
                    Set(strings).count == strings.count
                else {
                    let location = appendPointer(appendPointer(pointer, "dependentRequired"), name)
                    throw GenerationError.schema(
                        "malformed dependent requirement at #\(location): expected a non-empty array of unique strings"
                    )
                }
            }
        }
    }

    private func malformedKeyword(
        _ keyword: String, expected: String, pointer: String, sourceURL: URL
    ) -> GenerationError {
        GenerationError.schema(
            "malformed keyword '\(keyword)' at #\(appendPointer(pointer, keyword)) in '\(sourceURL.absoluteString)': expected \(expected)"
        )
    }

    private func unsupportedKeywords(in schema: JSONValue, draft: DraftVersion) -> Set<String> {
        var unsupported: Set<String> = [
            "$dynamicAnchor", "$dynamicRef", "$recursiveAnchor", "$recursiveRef", "contains",
            "dependentRequired", "dependentSchemas", "dependencies", "else",
            "exclusiveMaximum", "exclusiveMinimum", "format", "if", "maxContains", "maximum",
            "maxItems", "maxLength",
            "maxProperties", "minContains", "minimum", "minLength", "minProperties", "multipleOf",
            "not", "pattern",
            "patternProperties", "propertyNames", "then", "unevaluatedItems",
            "unevaluatedProperties", "uniqueItems",
        ]
        if schema["prefixItems"].array == nil && schema["items"].array == nil {
            unsupported.insert("minItems")
        }
        let isTuple =
            draft == .draft2020_12
            ? schema["prefixItems"].array != nil
            : schema["items"].array != nil
        if isTuple {
            unsupported.remove("maxItems")
        }
        if draft == .draft7 {
            unsupported.subtract([
                "$dynamicAnchor", "$dynamicRef", "$recursiveAnchor", "$recursiveRef",
                "dependentRequired", "dependentSchemas", "maxContains", "minContains",
                "unevaluatedItems", "unevaluatedProperties",
            ])
        } else if draft == .draft2019_09 {
            unsupported.remove("$dynamicAnchor")
            unsupported.remove("$dynamicRef")
        } else {
            unsupported.remove("$recursiveAnchor")
            unsupported.remove("$recursiveRef")
            unsupported.remove("dependencies")
        }
        return unsupported.filter { schema[$0].exists() }
    }
}

private func isValidSchemaAnchor(_ anchor: String) -> Bool {
    guard let first = anchor.first, first.isASCII, first.isLetter else { return false }
    return anchor.dropFirst().allSatisfy { character in
        character.isASCII
            && (character.isLetter || character.isNumber || "-_:.".contains(character))
    }
}

private func canonicalizedSchemaURL(_ url: URL) -> URL {
    url.isFileURL ? url.standardizedFileURL : url.absoluteURL
}

private func canonicalJSONString(_ json: JSONValue) -> String? {
    json.canonicalJSONString
}
