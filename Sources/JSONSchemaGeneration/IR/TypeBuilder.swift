import Foundation

struct TypeBuilder {
    private let documents: [URL: SchemaDocument]
    private let resolver: RefResolver
    private let options: GenerationOptions

    private var declarations: [String: TypeDeclIR] = [:]
    private var processingTypeNames: Set<String> = []
    private var processingTypeStack: [String] = []
    private var recursiveTypeNames: Set<String> = []
    private var resolvingAliasTargets: Set<String> = []
    private var resolvedSchemasByReferenceURL: [String: ResolvedSchema] = [:]
    private var resolvedReferenceTypes: [String: SwiftType] = [:]
    private var referenceNullability: [String: Bool] = [:]
    private var processingObjectShapeKeys: Set<String> = []
    private var activeDraft: DraftVersion = .draft2020_12
    private var generatedNameCounter = 0
    private var rootNamespaceByDocument: [URL: String] = [:]
    private var topLevelAliasesByName: [String: String] = [:]
    private var conflictingTopLevelAliases: Set<String> = []

    init(documents: [URL: SchemaDocument], resolver: RefResolver, options: GenerationOptions) {
        self.documents = documents
        self.resolver = resolver
        self.options = options
    }

    mutating func build() throws -> [TypeDeclIR] {
        let orderedDocuments = documents.values.sorted(by: {
            $0.url.absoluteString < $1.url.absoluteString
        })
        for document in orderedDocuments {
            rootNamespaceByDocument[document.url.standardizedFileURL] =
                documentRootNamespace(for: document)
        }

        // Entry point: each input file's root schema becomes (or contributes to) a top-level Swift type.
        for document in orderedDocuments {
            activeDraft = document.draft
            let rootNamespace =
                rootNamespaceByDocument[document.url.standardizedFileURL]
                ?? documentRootNamespace(for: document)
            let rootBaseURL = try resolver.effectiveBaseURL(for: document.json, from: document.url)
            registerTopLevelDefinitionAliases(
                in: document.json["$defs"].dictionaryValue, rootNamespace: rootNamespace)
            registerTopLevelDefinitionAliases(
                in: document.json["definitions"].dictionaryValue, rootNamespace: rootNamespace)

            if shouldMaterializeRootType(for: document.json) {
                let rootType = try typeForSchema(
                    document.json,
                    in: document.url,
                    suggestedName: rootNamespace,
                    forceNamedObject: true,
                    preferSuggestedName: true
                )
                if declarations[rootNamespace] == nil, rootType != .named(rootNamespace) {
                    _ = registerDeclaredTypeAlias(name: rootNamespace, target: rootType)
                }
            }

            // Schemas that only expose reusable definitions should still emit Swift types for those entries,
            // even when nothing in the root object references them directly.
            try materializeDefinitions(
                in: document.json["$defs"].dictionaryValue,
                namespace: [rootNamespace],
                documentURL: rootBaseURL,
                draft: document.draft
            )
            try materializeDefinitions(
                in: document.json["definitions"].dictionaryValue,
                namespace: [rootNamespace],
                documentURL: rootBaseURL,
                draft: document.draft
            )
        }

        return declarations.values.sorted(by: { $0.name < $1.name })
    }

    var topLevelDefinitionTypeAliases: [TypeAliasIR] {
        topLevelAliasesByName
            .filter { !conflictingTopLevelAliases.contains($0.key) && declarations[$0.key] == nil }
            .map { TypeAliasIR(name: $0.key, target: $0.value) }
            .sorted(by: { $0.name < $1.name })
    }

    private mutating func registerTopLevelDefinitionAliases(
        in definitions: [String: JSONValue], rootNamespace: String
    ) {
        for key in definitions.keys.sorted() {
            let schema = definitions[key] ?? .null
            guard isSchemaCandidate(schema) else { continue }

            let aliasName = IdentifierSanitizer.typeName(key, fallback: key)
            let aliasTarget = definitionTypeName(path: [rootNamespace, key], schema: schema)

            if declarations[aliasName] != nil {
                conflictingTopLevelAliases.insert(aliasName)
                topLevelAliasesByName.removeValue(forKey: aliasName)
                continue
            }

            if let existing = topLevelAliasesByName[aliasName], existing != aliasTarget {
                conflictingTopLevelAliases.insert(aliasName)
                topLevelAliasesByName.removeValue(forKey: aliasName)
                continue
            }

            if !conflictingTopLevelAliases.contains(aliasName) {
                topLevelAliasesByName[aliasName] = aliasTarget
            }
        }
    }

    private mutating func materializeDefinitions(
        in definitions: [String: JSONValue],
        namespace: [String],
        documentURL: URL,
        draft: DraftVersion
    ) throws {
        for key in definitions.keys.sorted() {
            let schema = definitions[key] ?? .null
            let path = namespace + [key]

            if isSchemaCandidate(schema) {
                let schemaDraft: DraftVersion
                if schema["$schema"].string != nil {
                    schemaDraft = try DraftVersion.detect(from: schema["$schema"].string)
                } else {
                    schemaDraft = draft
                }
                let schemaBaseURL = try resolver.effectiveBaseURL(for: schema, from: documentURL)
                let suggested = definitionTypeName(path: path, schema: schema)
                _ = try typeForSchema(
                    schema,
                    in: schemaBaseURL,
                    suggestedName: suggested,
                    forceNamedObject: true,
                    preferSuggestedName: true,
                    baseAlreadyApplied: true,
                    draft: schemaDraft
                )

                // Definitions can themselves embed nested `$defs`/`definitions`.
                try materializeDefinitions(
                    in: schema["$defs"].dictionaryValue, namespace: path,
                    documentURL: schemaBaseURL, draft: schemaDraft
                )
                try materializeDefinitions(
                    in: schema["definitions"].dictionaryValue, namespace: path,
                    documentURL: schemaBaseURL, draft: schemaDraft)
            } else if !schema.dictionaryValue.isEmpty {
                // Namespace container style: `definitions.v2.<Type>`.
                try materializeDefinitions(
                    in: schema.dictionaryValue, namespace: path, documentURL: documentURL,
                    draft: draft)
            }
        }
    }

    private mutating func typeForSchema(
        _ schema: JSONValue,
        in documentURL: URL,
        suggestedName: String,
        forceNamedObject: Bool = false,
        preferSuggestedName: Bool = false,
        baseAlreadyApplied: Bool = false,
        draft: DraftVersion? = nil
    ) throws -> SwiftType {
        let previousDraft = activeDraft
        if let draft {
            activeDraft = draft
        } else if schema["$schema"].string != nil {
            activeDraft = try DraftVersion.detect(from: schema["$schema"].string)
        }
        defer { activeDraft = previousDraft }
        let schemaBaseURL =
            baseAlreadyApplied
            ? documentURL
            : try resolver.effectiveBaseURL(for: schema, from: documentURL)
        // `true` accepts any JSONValue value. `false` accepts no value and cannot be represented
        // by a constructible Codable type.
        if schema.type == .bool {
            if schema.bool == false {
                throw GenerationError.codegen(
                    "the boolean schema 'false' has no representable Swift value (type '\(suggestedName)')"
                )
            }
            return .existential
        }

        // `$ref` branch: resolve pointer/file ref and continue on referenced schema.
        if let ref = schema["$ref"].string {
            let absoluteReference = URL(string: ref, relativeTo: schemaBaseURL)?.absoluteURL
            let absoluteReferenceKey = absoluteReference?.absoluteString ?? ref
            let resolved: ResolvedSchema
            if let cached = resolvedSchemasByReferenceURL[absoluteReferenceKey] {
                resolved = cached
            } else {
                resolved = try resolver.resolve(ref: ref, from: schemaBaseURL)
                resolvedSchemasByReferenceURL[absoluteReferenceKey] = resolved
            }
            let refFallback =
                suggestedName.isEmpty ? nextGeneratedName(prefix: "RefType") : suggestedName
            let refName = typeNameForRef(
                ref: ref,
                resolvedSchema: resolved.json,
                resolvedDocumentURL: resolved.documentURL,
                fallback: refFallback
            )
            if processingTypeNames.contains(refName) {
                markRecursiveCycle(endingAt: refName)
                return .named(refName)
            }
            let referenceCacheKey = "\(absoluteReferenceKey)|\(refName)"
            if let cached = resolvedReferenceTypes[referenceCacheKey] {
                return cached
            }
            let preserveSuggestedName = shouldPreferSuggestedNameForRef(ref)
            guard resolvingAliasTargets.insert(referenceCacheKey).inserted else {
                throw GenerationError.codegen(
                    "cyclic aliases without a structural object or union are unsupported (reference '\(ref)')"
                )
            }
            defer { resolvingAliasTargets.remove(referenceCacheKey) }
            let type = try typeForSchema(
                resolved.json,
                in: resolved.effectiveBaseURL,
                suggestedName: refName,
                forceNamedObject: true,
                preferSuggestedName: preserveSuggestedName,
                baseAlreadyApplied: true,
                draft: resolved.draft
            )
            resolvedReferenceTypes[referenceCacheKey] = type
            return type
        }

        // `allOf` => merged/intersection object model in Swift.
        if let allOf = schema["allOf"].array, !allOf.isEmpty {
            if allOf.count == 1, shouldTreatAllOfAsAlias(schema: schema) {
                return try typeForSchema(
                    allOf[0],
                    in: schemaBaseURL,
                    suggestedName: suggestedName,
                    forceNamedObject: forceNamedObject,
                    preferSuggestedName: preferSuggestedName
                )
            }
            if let siblingType = schema["type"].string, siblingType != "object" {
                throw GenerationError.codegen(
                    "allOf with sibling type '\(siblingType)' is currently unsupported (type '\(suggestedName)')"
                )
            }
            if schema["enum"].array != nil || schema["const"].exists() {
                throw GenerationError.codegen(
                    "allOf combined with enum or const is currently unsupported (type '\(suggestedName)')"
                )
            }
            let name = typeName(
                from: schema["title"].string,
                suggestedName: suggestedName,
                prefix: "AllOf",
                preferSuggestedName: preferSuggestedName
            )
            return try buildAllOfStruct(
                name: name,
                description: schema["description"].string,
                members: allOf,
                outerSchema: schema,
                documentURL: schemaBaseURL
            )
        }

        // `oneOf` => tagged union enum in Swift.
        if let oneOf = schema["oneOf"].array, !oneOf.isEmpty {
            if hasUnsupportedUnionSiblings(schema) {
                throw GenerationError.codegen(
                    "oneOf with sibling properties, required, enum, or const is currently unsupported (type '\(suggestedName)')"
                )
            }
            return try buildUnion(
                nameHint: suggestedName,
                title: schema["title"].string,
                description: schema["description"].string,
                variants: oneOf,
                documentURL: schemaBaseURL,
                unionKind: .oneOf,
                preferSuggestedName: preferSuggestedName
            )
        }

        // `anyOf` => union enum in Swift (same output representation as `oneOf`).
        if let anyOf = schema["anyOf"].array, !anyOf.isEmpty {
            if hasUnsupportedUnionSiblings(schema) {
                throw GenerationError.codegen(
                    "anyOf with sibling properties, required, enum, or const is currently unsupported (type '\(suggestedName)')"
                )
            }
            return try buildUnion(
                nameHint: suggestedName,
                title: schema["title"].string,
                description: schema["description"].string,
                variants: anyOf,
                documentURL: schemaBaseURL,
                unionKind: .anyOf,
                preferSuggestedName: preferSuggestedName
            )
        }

        if schema["const"].exists() {
            guard let literal = scalarLiteral(schema["const"]) else {
                throw GenerationError.codegen(
                    "only scalar and null const values are supported (type '\(suggestedName)')")
            }
            guard literalIsCompatibleWithDeclaredType(literal, schema: schema) else {
                throw GenerationError.codegen(
                    "const is incompatible with its declared type (type '\(suggestedName)')"
                )
            }
            if let enumValues = schema["enum"].array {
                let enumLiterals = enumValues.compactMap(scalarLiteral)
                guard enumLiterals.count == enumValues.count, enumLiterals.contains(literal) else {
                    throw GenerationError.codegen(
                        "const is not included in the sibling enum (type '\(suggestedName)')"
                    )
                }
            }
            return try buildLiteralEnum(
                name: typeName(
                    from: schema["title"].string,
                    suggestedName: suggestedName,
                    prefix: "Constant",
                    preferSuggestedName: preferSuggestedName
                ),
                description: schema["description"].string,
                literals: [literal]
            )
        }

        // Scalar/object/array type in `"type": "..."`.
        if let enumValues = schema["enum"].array, !enumValues.isEmpty,
            !(schema["type"].string == "string" && enumValues.allSatisfy({ $0.type == .string }))
        {
            let allLiterals = enumValues.compactMap(scalarLiteral)
            guard allLiterals.count == enumValues.count else {
                throw GenerationError.codegen(
                    "only scalar and null enum values are supported (type '\(suggestedName)')")
            }
            let literals = allLiterals.filter {
                literalIsCompatibleWithDeclaredType($0, schema: schema)
            }
            guard !literals.isEmpty else {
                throw GenerationError.codegen(
                    "enum has no values compatible with its declared type (type '\(suggestedName)')"
                )
            }
            return try buildLiteralEnum(
                name: typeName(
                    from: schema["title"].string,
                    suggestedName: suggestedName,
                    prefix: "Enum",
                    preferSuggestedName: preferSuggestedName
                ),
                description: schema["description"].string,
                literals: literals
            )
        }

        if let typeString = schema["type"].string {
            return try typeFromExplicitType(
                typeString,
                schema: schema,
                documentURL: schemaBaseURL,
                suggestedName: suggestedName,
                forceNamedObject: forceNamedObject,
                preferSuggestedName: preferSuggestedName
            )
        }

        // Union/nullability via `"type": ["...", ...]`.
        if let typeArray = schema["type"].array {
            let typeNames = typeArray.compactMap(\.string)
            return try typeFromTypeArray(
                typeNames,
                schema: schema,
                documentURL: schemaBaseURL,
                suggestedName: suggestedName,
                forceNamedObject: forceNamedObject,
                preferSuggestedName: preferSuggestedName
            )
        }

        // Object shape can also be implied by `properties`/`required` without explicit `"type": "object"`.
        if !schema["properties"].dictionaryValue.isEmpty || schema["required"].array != nil {
            let name = typeName(
                from: schema["title"].string,
                suggestedName: suggestedName,
                prefix: "Object",
                preferSuggestedName: preferSuggestedName
            )
            return try buildStruct(name: name, schema: schema, documentURL: schemaBaseURL)
        }

        // Array shape can also be implied by `items`/`prefixItems` without explicit `"type": "array"`.
        if schema["items"].exists() || schema["prefixItems"].exists() {
            return try arrayType(
                schema: schema, documentURL: schemaBaseURL, suggestedName: suggestedName)
        }

        // An untyped enum retains every supported scalar and null literal.
        if schema["enum"].array != nil {
            let values = schema["enum"].arrayValue
            let literals = values.compactMap(scalarLiteral)
            guard literals.count == values.count else {
                throw GenerationError.codegen(
                    "only scalar and null enum values are supported (type '\(suggestedName)')")
            }
            return try buildLiteralEnum(
                name: typeName(
                    from: schema["title"].string,
                    suggestedName: suggestedName,
                    prefix: "Enum",
                    preferSuggestedName: preferSuggestedName
                ),
                description: schema["description"].string,
                literals: literals
            )
        }

        if forceNamedObject {
            return .existential
        }
        return .existential
    }

    private func hasUnsupportedUnionSiblings(_ schema: JSONValue) -> Bool {
        !schema["properties"].dictionaryValue.isEmpty
            || schema["required"].array != nil
            || schema["enum"].array != nil
            || schema["const"].exists()
    }

    private mutating func typeFromExplicitType(
        _ type: String,
        schema: JSONValue,
        documentURL: URL,
        suggestedName: String,
        forceNamedObject: Bool,
        preferSuggestedName: Bool
    ) throws -> SwiftType {
        if type == "string", let enumValues = schema["enum"].array, !enumValues.isEmpty {
            let values = enumValues.compactMap(\.string)
            if values.count == enumValues.count {
                let name = typeName(
                    from: schema["title"].string,
                    suggestedName: suggestedName,
                    prefix: "StringEnum",
                    preferSuggestedName: preferSuggestedName
                )
                return try buildRawStringEnum(
                    name: name, values: values, description: schema["description"].string)
            }
        }

        switch type {
        case "string":
            return maybeDeclareSimpleTypeAlias(
                base: .string,
                schema: schema,
                suggestedName: suggestedName,
                preferSuggestedName: preferSuggestedName,
                prefix: "StringAlias"
            )
        case "integer":
            return maybeDeclareSimpleTypeAlias(
                base: .int,
                schema: schema,
                suggestedName: suggestedName,
                preferSuggestedName: preferSuggestedName,
                prefix: "IntegerAlias"
            )
        case "number":
            return maybeDeclareSimpleTypeAlias(
                base: .double,
                schema: schema,
                suggestedName: suggestedName,
                preferSuggestedName: preferSuggestedName,
                prefix: "NumberAlias"
            )
        case "boolean":
            return maybeDeclareSimpleTypeAlias(
                base: .bool,
                schema: schema,
                suggestedName: suggestedName,
                preferSuggestedName: preferSuggestedName,
                prefix: "BoolAlias"
            )
        case "array":
            return try arrayType(
                schema: schema, documentURL: documentURL, suggestedName: suggestedName)
        case "object":
            // Map-payload object case: `{ "type": "object", "additionalProperties": ... }`.
            if !forceNamedObject,
                schema["properties"].dictionaryValue.isEmpty
            {
                let valueSchema = schema["additionalProperties"]
                if !valueSchema.exists() || (valueSchema.type == .bool && valueSchema.bool == true)
                {
                    return .dictionary(.existential)
                }
                if valueSchema.type == .bool && valueSchema.bool == false {
                    let name = typeName(
                        from: schema["title"].string,
                        suggestedName: suggestedName,
                        prefix: "Object",
                        preferSuggestedName: preferSuggestedName
                    )
                    return try buildStruct(name: name, schema: schema, documentURL: documentURL)
                }
                let valueType = try typeForSchema(
                    valueSchema, in: documentURL, suggestedName: "\(suggestedName)Value")
                return .dictionary(valueType)
            }
            let name = typeName(
                from: schema["title"].string,
                suggestedName: suggestedName,
                prefix: "Object",
                preferSuggestedName: preferSuggestedName
            )
            return try buildStruct(name: name, schema: schema, documentURL: documentURL)
        case "null":
            return .null
        default:
            return .existential
        }
    }

    private mutating func typeFromTypeArray(
        _ types: [String],
        schema: JSONValue,
        documentURL: URL,
        suggestedName: String,
        forceNamedObject: Bool,
        preferSuggestedName: Bool
    ) throws -> SwiftType {
        if types.count == 1, types[0] == "null" {
            return .null
        }

        // Common nullable form: `["T", "null"]` => Optional<T>.
        let nonNull = types.filter { $0 != "null" }
        if nonNull.count == 1 && types.count == 2 {
            let base = try typeFromExplicitType(
                nonNull[0],
                schema: schema,
                documentURL: documentURL,
                suggestedName: suggestedName,
                forceNamedObject: forceNamedObject,
                preferSuggestedName: preferSuggestedName
            )
            return .optional(base)
        }

        // Other multi-type forms are modeled as unions by synthesizing per-type schema stubs.
        let syntheticVariants = nonNull.map { value -> JSONValue in
            var object = JSONValue.object([:])
            object["type"] = .string(value)
            return object
        }
        var variants = syntheticVariants
        if types.contains("null") {
            var nullSchema = JSONValue.object([:])
            nullSchema["type"] = .string("null")
            variants.append(nullSchema)
        }
        return try buildUnion(
            nameHint: suggestedName,
            title: schema["title"].string,
            description: schema["description"].string,
            variants: variants,
            documentURL: documentURL,
            preferSuggestedName: preferSuggestedName
        )
    }

    private mutating func arrayType(schema: JSONValue, documentURL: URL, suggestedName: String)
        throws
        -> SwiftType
    {
        let draft = activeDraft
        let usesPrefixItems = draft == .draft2020_12
        let tupleSchemas = usesPrefixItems ? schema["prefixItems"].array : schema["items"].array
        if let tupleSchemas, !tupleSchemas.isEmpty {
            return try buildTuple(
                name: typeName(
                    from: schema["title"].string, suggestedName: suggestedName, prefix: "Tuple"),
                description: schema["description"].string,
                elementSchemas: tupleSchemas,
                schema: schema,
                documentURL: documentURL,
                usesPrefixItems: usesPrefixItems
            )
        }

        if schema["items"].exists() {
            if schema["items"].type == .bool {
                if schema["items"].bool == false {
                    return try buildTuple(
                        name: typeName(
                            from: schema["title"].string,
                            suggestedName: suggestedName,
                            prefix: "EmptyArray"
                        ),
                        description: schema["description"].string,
                        elementSchemas: [],
                        schema: schema,
                        documentURL: documentURL,
                        usesPrefixItems: true
                    )
                }
                return .array(.existential)
            }
            let item = try typeForSchema(
                schema["items"], in: documentURL, suggestedName: "\(suggestedName)Item")
            return .array(item)
        }
        return .array(.existential)
    }

    private func draftVersion(for baseURL: URL) -> DraftVersion {
        if let direct = documents[baseURL.standardizedFileURL]?.draft {
            return direct
        }
        for document in documents.values {
            if let rootBase = try? resolver.effectiveBaseURL(
                for: document.json, from: document.url),
                rootBase == baseURL
            {
                return document.draft
            }
        }
        return activeDraft
    }

    private mutating func buildTuple(
        name: String,
        description: String?,
        elementSchemas: [JSONValue],
        schema: JSONValue,
        documentURL: URL,
        usesPrefixItems: Bool
    ) throws -> SwiftType {
        if processingTypeNames.contains(name) {
            markRecursiveCycle(endingAt: name)
            return .named(name)
        }
        beginProcessing(name)
        defer { endProcessing(name) }

        let minimumCount = schema["minItems"].int ?? 0
        guard minimumCount == elementSchemas.count else {
            throw GenerationError.codegen(
                "tuple minItems must equal its prefix length \(elementSchemas.count) for lossless generation (type '\(name)')"
            )
        }
        let maximumCount = schema["maxItems"].int
        if let maximumCount, maximumCount < elementSchemas.count {
            throw GenerationError.codegen(
                "maxItems \(maximumCount) is smaller than the tuple prefix length \(elementSchemas.count) (type '\(name)')"
            )
        }
        var elements: [TupleElementIR] = []
        for (index, elementSchema) in elementSchemas.enumerated() {
            let elementType = try typeForSchema(
                elementSchema,
                in: documentURL,
                suggestedName: "\(name).Item\(index + 1)"
            )
            elements.append(.init(name: "item\(index + 1)", type: elementType))
        }

        let additionalSchema = usesPrefixItems ? schema["items"] : schema["additionalItems"]
        let additionalElementType: SwiftType?
        if maximumCount == elementSchemas.count {
            additionalElementType = nil
        } else if !additionalSchema.exists()
            || (additionalSchema.type == .bool && additionalSchema.bool == true)
        {
            additionalElementType = .existential
        } else if additionalSchema.type == .bool && additionalSchema.bool == false {
            additionalElementType = nil
        } else {
            additionalElementType = try typeForSchema(
                additionalSchema,
                in: documentURL,
                suggestedName: "\(name).AdditionalItem"
            )
        }

        declarations[name] = .tupleDecl(
            TupleIR(
                name: name,
                description: description,
                elements: elements,
                additionalElementType: additionalElementType,
                maximumCount: maximumCount
            )
        )
        return .named(name)
    }

    private mutating func buildStruct(name: String, schema: JSONValue, documentURL: URL) throws
        -> SwiftType
    {
        if processingTypeNames.contains(name) {
            markRecursiveCycle(endingAt: name)
            return .named(name)
        }
        beginProcessing(name)
        defer { endProcessing(name) }

        // `required` controls Optional vs non-Optional property emission.
        let requiredSet = Set(schema["required"].arrayValue.compactMap(\.string))
        let props = schema["properties"].dictionaryValue

        var parsedProperties: [PropertyIR] = []
        for key in props.keys.sorted() {
            let fallback = "field\(nextGeneratedName(prefix: ""))"
            let swiftName = IdentifierSanitizer.propertyName(key, fallback: fallback)
            let suggested = suggestedNestedTypeName(parent: name, key: key, fallbackPrefix: "Type")
            var propertyType = try typeForSchema(
                props[key] ?? JSONValue.null, in: documentURL, suggestedName: suggested)
            let required = requiredSet.contains(key)
            if !required {
                propertyType = propertyType.wrappedOptional()
            }

            parsedProperties.append(
                PropertyIR(
                    schemaKey: key,
                    swiftName: swiftName,
                    type: propertyType,
                    requiredByAllInputs: required,
                    allowsNull: try schemaAllowsNull(props[key] ?? .null, documentURL: documentURL)
                )
            )
        }

        let additionalProperties = try buildAdditionalProperties(
            schema: schema,
            documentURL: documentURL,
            suggestedName: "\(name).AdditionalProperty"
        )
        let newStruct = StructIR(
            name: name,
            description: schema["description"].string,
            properties: parsedProperties,
            isReferenceType: recursiveTypeNames.contains(name),
            additionalProperties: additionalProperties
        )
        if case .structDecl(let existing)? = declarations[name] {
            declarations[name] = .structDecl(try mergeStruct(existing, with: newStruct))
        } else {
            declarations[name] = .structDecl(newStruct)
        }
        return .named(name)
    }

    private mutating func buildAdditionalProperties(
        schema: JSONValue,
        documentURL: URL,
        suggestedName: String
    ) throws -> AdditionalPropertiesIR {
        let additional = schema["additionalProperties"]
        guard additional.exists() else { return .captured(.existential) }
        if additional.type == .bool {
            return additional.bool == false ? .forbidden : .captured(.existential)
        }
        return .captured(
            try typeForSchema(
                additional,
                in: documentURL,
                suggestedName: suggestedName
            )
        )
    }

    private mutating func buildAllOfStruct(
        name: String,
        description: String?,
        members: [JSONValue],
        outerSchema: JSONValue,
        documentURL: URL
    ) throws -> SwiftType {
        if processingTypeNames.contains(name) {
            markRecursiveCycle(endingAt: name)
            return .named(name)
        }
        beginProcessing(name)
        defer { endProcessing(name) }

        // `allOf` is modeled as an intersection of object properties.
        var merged: StructIR = .init(
            name: name,
            description: description,
            properties: [],
            isReferenceType: recursiveTypeNames.contains(name),
            additionalProperties: try buildAdditionalProperties(
                schema: outerSchema,
                documentURL: documentURL,
                suggestedName: "\(name).AdditionalProperty"
            )
        )
        for (index, member) in members.enumerated() {
            let partName = "\(name).Part\(index + 1)"
            if member["additionalProperties"].exists() {
                throw GenerationError.codegen(
                    "additionalProperties inside allOf members is currently unsupported (member \(index + 1) of type '\(name)')"
                )
            }
            if let objectShape = try objectShape(
                from: member, documentURL: documentURL, nameHint: partName)
            {
                merged = try mergeIntersectionStruct(
                    merged,
                    with: StructIR(name: name, description: nil, properties: objectShape)
                )
            } else {
                throw GenerationError.codegen(
                    "allOf currently supports object intersections only (member \(index + 1) of type '\(name)')"
                )
            }
        }

        if !outerSchema["properties"].dictionaryValue.isEmpty
            || outerSchema["required"].array != nil
        {
            var ownObject = JSONValue.object([:])
            ownObject["type"] = .string("object")
            ownObject["properties"] = outerSchema["properties"]
            ownObject["required"] = outerSchema["required"]
            if let ownProperties = try objectShape(
                from: ownObject,
                documentURL: documentURL,
                nameHint: "\(name).OwnProperties"
            ) {
                merged = try mergeIntersectionStruct(
                    merged,
                    with: StructIR(name: name, description: nil, properties: ownProperties)
                )
            }
        }

        if case .structDecl(let existing)? = declarations[name] {
            declarations[name] = .structDecl(try mergeStruct(existing, with: merged))
        } else {
            declarations[name] = .structDecl(merged)
        }

        return .named(name)
    }

    private mutating func objectShape(
        from schema: JSONValue,
        documentURL: URL,
        nameHint: String,
        baseAlreadyApplied: Bool = false
    ) throws -> [PropertyIR]? {
        let schemaBaseURL =
            baseAlreadyApplied
            ? documentURL
            : try resolver.effectiveBaseURL(for: schema, from: documentURL)
        let shapeKey = "\(schemaBaseURL.absoluteString)|\(schema.canonicalJSONString ?? "")"
        guard processingObjectShapeKeys.insert(shapeKey).inserted else {
            throw GenerationError.codegen(
                "cyclic allOf aliases without a concrete object shape are unsupported (type '\(nameHint)')"
            )
        }
        defer { processingObjectShapeKeys.remove(shapeKey) }
        if let ref = schema["$ref"].string {
            let resolved = try resolver.resolve(ref: ref, from: schemaBaseURL)
            return try objectShape(
                from: resolved.json,
                documentURL: resolved.effectiveBaseURL,
                nameHint: nameHint,
                baseAlreadyApplied: true
            )
        }

        if let allOf = schema["allOf"].array, !allOf.isEmpty {
            var merged: StructIR = .init(name: nameHint, description: nil, properties: [])
            for (index, item) in allOf.enumerated() {
                guard
                    let part = try objectShape(
                        from: item,
                        documentURL: schemaBaseURL,
                        nameHint: "\(nameHint).Part\(index + 1)"
                    )
                else { return nil }
                merged = try mergeIntersectionStruct(
                    merged,
                    with: StructIR(name: nameHint, description: nil, properties: part)
                )
            }
            return merged.properties
        }

        // Used by `allOf` merge: attempts to flatten object-like members into property lists.
        if schema["additionalProperties"].exists() {
            throw GenerationError.codegen(
                "additionalProperties inside intersection members is currently unsupported (type '\(nameHint)')"
            )
        }

        if schema["type"].string == "object" || !schema["properties"].dictionaryValue.isEmpty
            || schema["required"].array != nil
        {
            let requiredSet = Set(schema["required"].arrayValue.compactMap(\.string))
            var result: [PropertyIR] = []
            for key in schema["properties"].dictionaryValue.keys.sorted() {
                let swiftName = IdentifierSanitizer.propertyName(
                    key, fallback: "field\(result.count + 1)")
                let suggested = suggestedNestedTypeName(
                    parent: nameHint, key: key, fallbackPrefix: "ShapeType")
                var propertyType = try typeForSchema(
                    schema["properties"][key], in: schemaBaseURL, suggestedName: suggested)
                let required = requiredSet.contains(key)
                if !required {
                    propertyType = propertyType.wrappedOptional()
                }
                result.append(
                    PropertyIR(
                        schemaKey: key,
                        swiftName: swiftName,
                        type: propertyType,
                        requiredByAllInputs: required,
                        allowsNull: try schemaAllowsNull(
                            schema["properties"][key], documentURL: schemaBaseURL)
                    )
                )
            }
            return result
        }

        return nil
    }

    private func mergeIntersectionStruct(_ lhs: StructIR, with rhs: StructIR) throws -> StructIR {
        var properties = Dictionary(uniqueKeysWithValues: lhs.properties.map { ($0.schemaKey, $0) })
        for incoming in rhs.properties {
            guard let existing = properties[incoming.schemaKey] else {
                properties[incoming.schemaKey] = incoming
                continue
            }
            let existingBase = unwrapOptional(existing.type)
            let incomingBase = unwrapOptional(incoming.type)
            guard existingBase == incomingBase else {
                throw GenerationError.codegen(
                    "allOf property '\(incoming.schemaKey)' has incompatible Swift types '\(existingBase.rendered)' and '\(incomingBase.rendered)'"
                )
            }
            let required = existing.requiredByAllInputs || incoming.requiredByAllInputs
            let allowsNull = existing.allowsNull && incoming.allowsNull
            properties[incoming.schemaKey] = PropertyIR(
                schemaKey: incoming.schemaKey,
                swiftName: incoming.swiftName,
                type: required && !allowsNull ? existingBase : existingBase.wrappedOptional(),
                requiredByAllInputs: required,
                allowsNull: allowsNull
            )
        }
        return StructIR(
            name: lhs.name,
            description: chooseDescription(lhs.description, rhs.description),
            properties: properties.values.sorted(by: { $0.schemaKey < $1.schemaKey }),
            isReferenceType: lhs.isReferenceType || rhs.isReferenceType,
            additionalProperties: mergeAdditionalProperties(
                lhs.additionalProperties, rhs.additionalProperties)
        )
    }

    private mutating func buildUnion(
        nameHint: String,
        title: String?,
        description: String?,
        variants: [JSONValue],
        documentURL: URL,
        unionKind: UnionKind = .anyOf,
        preferSuggestedName: Bool
    ) throws -> SwiftType {
        var nonNullVariants: [(json: JSONValue, index: Int)] = []
        var nullVariantIndices: [Int] = []

        for (index, variant) in variants.enumerated() {
            if isNullSchema(variant) {
                nullVariantIndices.append(index)
                continue
            }
            nonNullVariants.append((variant, index))
        }

        // `null` + one variant => Optional<Variant>; broader nullable unions stay enum-based.
        let canCollapseNullable: Bool
        if nullVariantIndices.count == 1, nonNullVariants.count == 1 {
            if unionKind == .anyOf {
                canCollapseNullable = true
            } else {
                canCollapseNullable =
                    !(try schemaAllowsNull(
                        nonNullVariants[0].json, documentURL: documentURL))
            }
        } else {
            canCollapseNullable = false
        }
        if canCollapseNullable {
            let single = nonNullVariants[0]
            let inferred = try typeForSchema(
                single.json, in: documentURL, suggestedName: "\(nameHint)Value")
            return .optional(inferred)
        }

        let unionName = typeName(
            from: title, suggestedName: nameHint, prefix: "Type",
            preferSuggestedName: preferSuggestedName)
        if processingTypeNames.contains(unionName) {
            markRecursiveCycle(endingAt: unionName)
            return .named(unionName)
        }
        beginProcessing(unionName)
        defer { endProcessing(unionName) }
        let discriminatorKey = try detectUnionDiscriminatorKey(
            nonNullVariants: nonNullVariants, documentURL: documentURL)
        var types: [SwiftType] = []
        var literals: [EnumCaseLiteralIR?] = []
        var titleHints: [String?] = []
        var caseHints: [String?] = []
        var caseDescriptions: [String?] = []

        for entry in nonNullVariants {
            if let enumLiterals = scalarEnumLiterals(entry.json), !enumLiterals.isEmpty {
                for literal in enumLiterals {
                    types.append(.existential)
                    literals.append(literal)
                    titleHints.append(entry.json["title"].string)
                    caseHints.append(singleScalarEnumCaseHint(literal))
                    caseDescriptions.append(entry.json["description"].string)
                }
                continue
            }

            let defaultSuggested = "\(unionName).Variant\(entry.index + 1)"
            let inlineTitle = entry.json["title"].string
            let hasRef = entry.json["$ref"].string != nil

            let suggested: String
            let preferVariantSuggested: Bool
            if !hasRef, let inlineTitle,
                !inlineTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                let localName = IdentifierSanitizer.typeName(
                    inlineTitle, fallback: defaultSuggested)
                suggested = "\(unionName).\(localName)"
                preferVariantSuggested = true
            } else {
                suggested = defaultSuggested
                preferVariantSuggested = false
            }

            types.append(
                try typeForSchema(
                    entry.json,
                    in: documentURL,
                    suggestedName: suggested,
                    preferSuggestedName: preferSuggestedName || preferVariantSuggested
                )
            )
            let discriminatorValue: String?
            if let discriminatorKey {
                discriminatorValue = try variantDiscriminatorLiteral(
                    variant: entry.json,
                    key: discriminatorKey,
                    documentURL: documentURL
                )
            } else {
                discriminatorValue = nil
            }
            if let discriminatorValue {
                literals.append(.string(discriminatorValue))
            } else {
                literals.append(nil)
            }
            titleHints.append(entry.json["title"].string)

            var caseHint = entry.json["title"].string
            if let discriminatorValue {
                caseHint = discriminatorValue
            }
            var caseDescription = entry.json["description"].string
            // For `$ref` union variants, prefer referenced definition name/description for enum case/docs.
            if let ref = entry.json["$ref"].string {
                caseHint = caseHint ?? ref.lastDecodedSchemaRefToken
                let resolved = try resolver.resolve(ref: ref, from: documentURL)
                caseHint = caseHint ?? resolved.json["title"].string
                caseDescription = caseDescription ?? resolved.json["description"].string
            }
            caseHints.append(caseHint)
            caseDescriptions.append(caseDescription)
        }

        for _ in nullVariantIndices {
            types.append(.existential)
            literals.append(nil)
            titleHints.append("null")
            caseHints.append("null")
            caseDescriptions.append(nil)
        }

        return try makeUnionType(
            unionName: unionName,
            variantTypes: types,
            variantLiterals: literals,
            variantTitleHints: titleHints,
            variantCaseHints: caseHints,
            variantDescriptions: caseDescriptions,
            discriminatorKey: discriminatorKey,
            unionKind: unionKind,
            description: description
        )
    }

    private mutating func makeUnionType(
        unionName: String,
        variantTypes: [SwiftType],
        variantLiterals: [EnumCaseLiteralIR?] = [],
        variantTitleHints: [String?],
        variantCaseHints: [String?],
        variantDescriptions: [String?],
        discriminatorKey: String? = nil,
        unionKind: UnionKind = .anyOf,
        description: String?
    ) throws -> SwiftType {
        var enumCases: [EnumCaseIR] = []
        var usedCaseNames: Set<String> = []

        for (index, variantType) in variantTypes.enumerated() {
            let hint = variantTitleHints.indices.contains(index) ? variantTitleHints[index] : nil
            let literal = variantLiterals.indices.contains(index) ? variantLiterals[index] : nil
            let caseHint = variantCaseHints.indices.contains(index) ? variantCaseHints[index] : nil
            let caseDescription =
                variantDescriptions.indices.contains(index) ? variantDescriptions[index] : nil
            let caseName = nextEnumCaseName(
                hint: caseHint ?? hint,
                fallback: fallbackEnumCaseName(for: variantType, index: index + 1),
                used: &usedCaseNames
            )
            if hint == "null" {
                enumCases.append(
                    EnumCaseIR(
                        name: caseName, description: caseDescription, associatedType: nil,
                        literal: nil))
            } else if let literal {
                if variantType == .existential {
                    // Flattened scalar enum literals become payload-less cases.
                    enumCases.append(
                        EnumCaseIR(
                            name: caseName, description: caseDescription, associatedType: nil,
                            literal: literal))
                } else {
                    // Discriminated object variants keep associated payload type.
                    enumCases.append(
                        EnumCaseIR(
                            name: caseName, description: caseDescription,
                            associatedType: variantType, literal: literal))
                }
            } else {
                enumCases.append(
                    EnumCaseIR(
                        name: caseName, description: caseDescription, associatedType: variantType,
                        literal: nil))
            }
        }

        let incoming = EnumIR(
            name: unionName,
            description: description,
            discriminatorKey: discriminatorKey,
            cases: enumCases,
            unionKind: unionKind,
            isIndirect: recursiveTypeNames.contains(unionName)
        )
        if case .enumDecl(let existing)? = declarations[unionName] {
            declarations[unionName] = .enumDecl(mergeEnum(existing, with: incoming))
        } else {
            declarations[unionName] = .enumDecl(incoming)
        }
        return .named(unionName)
    }

    private mutating func buildLiteralEnum(
        name: String,
        description: String?,
        literals: [EnumCaseLiteralIR]
    ) throws -> SwiftType {
        try makeUnionType(
            unionName: name,
            variantTypes: Array(repeating: .existential, count: literals.count),
            variantLiterals: literals.map(Optional.some),
            variantTitleHints: Array(repeating: nil, count: literals.count),
            variantCaseHints: literals.map(singleScalarEnumCaseHint),
            variantDescriptions: Array(repeating: nil, count: literals.count),
            unionKind: .oneOf,
            description: description
        )
    }

    private mutating func buildRawStringEnum(name: String, values: [String], description: String?)
        throws -> SwiftType
    {
        var used: Set<String> = []
        var cases: [RawEnumCaseIR] = []
        for (index, rawValue) in values.enumerated() {
            var caseName = IdentifierSanitizer.enumCaseName(rawValue, fallback: "value\(index + 1)")
            if caseName == "`null`" || caseName == "null" {
                caseName = "nullValue"
            }
            if used.contains(caseName) {
                var suffix = 2
                while used.contains("\(caseName)\(suffix)") {
                    suffix += 1
                }
                caseName = "\(caseName)\(suffix)"
            }
            used.insert(caseName)
            cases.append(RawEnumCaseIR(name: caseName, rawValue: rawValue))
        }

        let incoming = RawEnumIR(name: name, description: description, cases: cases)
        if case .rawStringEnumDecl(let existing)? = declarations[name] {
            declarations[name] = .rawStringEnumDecl(mergeRawStringEnum(existing, with: incoming))
        } else if declarations[name] == nil {
            declarations[name] = .rawStringEnumDecl(incoming)
        }
        return .named(name)
    }

    private mutating func maybeDeclareSimpleTypeAlias(
        base: SwiftType,
        schema: JSONValue,
        suggestedName: String,
        preferSuggestedName: Bool,
        prefix: String
    ) -> SwiftType {
        guard
            shouldDeclareSimpleTypeAlias(
                schema: schema, suggestedName: suggestedName,
                preferSuggestedName: preferSuggestedName)
        else {
            return base
        }

        let aliasName = typeName(
            from: schema["title"].string,
            suggestedName: suggestedName,
            prefix: prefix,
            preferSuggestedName: preferSuggestedName
        )

        if registerDeclaredTypeAlias(name: aliasName, target: base) {
            return .named(aliasName)
        }
        return base
    }

    private func shouldDeclareSimpleTypeAlias(
        schema: JSONValue, suggestedName: String, preferSuggestedName: Bool
    ) -> Bool {
        if schema["enum"].array != nil {
            return false
        }

        if schema["title"].string.trimmedNonEmpty != nil {
            return true
        }

        guard preferSuggestedName else { return false }

        let leaf = suggestedName.split(separator: ".").last.map(String.init) ?? suggestedName
        if leaf.hasPrefix("Variant"), leaf.dropFirst("Variant".count).allSatisfy(\.isNumber) {
            return false
        }
        if leaf.hasPrefix("Part"), leaf.dropFirst("Part".count).allSatisfy(\.isNumber) {
            return false
        }
        return true
    }

    @discardableResult
    private mutating func registerDeclaredTypeAlias(name: String, target: SwiftType) -> Bool {
        if let existing = declarations[name] {
            if case .typeAliasDecl(let alias) = existing, alias.target == target {
                return true
            }
            return false
        }
        declarations[name] = .typeAliasDecl(DeclaredTypeAliasIR(name: name, target: target))
        return true
    }

    private func mergeEnum(_ lhs: EnumIR, with rhs: EnumIR) -> EnumIR {
        var merged = lhs.cases
        var seen: Set<String> = Set(merged.map(\.name))
        for item in rhs.cases where !seen.contains(item.name) {
            merged.append(item)
            seen.insert(item.name)
        }
        let discriminatorKey: String?
        if lhs.discriminatorKey == rhs.discriminatorKey {
            discriminatorKey = lhs.discriminatorKey
        } else {
            discriminatorKey = lhs.discriminatorKey ?? rhs.discriminatorKey
        }
        return EnumIR(
            name: lhs.name,
            description: chooseDescription(lhs.description, rhs.description),
            discriminatorKey: discriminatorKey,
            cases: merged,
            unionKind: lhs.unionKind == .oneOf || rhs.unionKind == .oneOf ? .oneOf : .anyOf,
            isIndirect: lhs.isIndirect || rhs.isIndirect || recursiveTypeNames.contains(lhs.name)
        )
    }

    private func mergeRawStringEnum(_ lhs: RawEnumIR, with rhs: RawEnumIR) -> RawEnumIR {
        var merged = lhs.cases
        var seen: Set<String> = Set(merged.map(\.rawValue))
        for item in rhs.cases where !seen.contains(item.rawValue) {
            merged.append(item)
            seen.insert(item.rawValue)
        }
        return RawEnumIR(
            name: lhs.name, description: chooseDescription(lhs.description, rhs.description),
            cases: merged)
    }

    private mutating func mergeStruct(_ lhs: StructIR, with rhs: StructIR) throws -> StructIR {
        var map: [String: PropertyIR] = [:]
        for property in lhs.properties {
            map[property.schemaKey] = property
        }

        for property in rhs.properties {
            guard let existing = map[property.schemaKey] else {
                map[property.schemaKey] = property
                continue
            }
            // Duplicate-title or allOf property conflicts become union property types.
            map[property.schemaKey] = try mergeProperty(
                existing: existing, incoming: property, ownerTypeName: lhs.name)
        }

        let mergedProperties = map.values.sorted(by: { $0.schemaKey < $1.schemaKey })
        return StructIR(
            name: lhs.name,
            description: chooseDescription(lhs.description, rhs.description),
            properties: mergedProperties,
            isReferenceType: lhs.isReferenceType || rhs.isReferenceType
                || recursiveTypeNames.contains(lhs.name),
            additionalProperties: mergeAdditionalProperties(
                lhs.additionalProperties, rhs.additionalProperties)
        )
    }

    private func mergeAdditionalProperties(
        _ lhs: AdditionalPropertiesIR,
        _ rhs: AdditionalPropertiesIR
    ) -> AdditionalPropertiesIR {
        switch (lhs, rhs) {
        case (.forbidden, _), (_, .forbidden):
            return .forbidden
        case (.captured(let left), .captured(let right)):
            return left == right ? .captured(left) : .ignored
        case (.captured(let value), .ignored), (.ignored, .captured(let value)):
            return .captured(value)
        case (.ignored, .ignored):
            return .ignored
        }
    }

    private mutating func mergeProperty(
        existing: PropertyIR, incoming: PropertyIR, ownerTypeName: String
    ) throws -> PropertyIR {
        let existingOptional = existing.type.isOptional
        let incomingOptional = incoming.type.isOptional
        let existingBase = unwrapOptional(existing.type)
        let incomingBase = unwrapOptional(incoming.type)

        let mergedBase: SwiftType
        if existingBase == incomingBase {
            mergedBase = existingBase
        } else {
            let local = IdentifierSanitizer.typeName(
                incoming.swiftName.replacingOccurrences(of: "`", with: "").capitalized,
                fallback: nextGeneratedName(prefix: "ConflictType")
            )
            let unionName = qualifiedTypeName(
                from: "\(ownerTypeName).\(local)",
                fallback: nextGeneratedName(prefix: "ConflictType")
            )
            mergedBase = try makeUnionType(
                unionName: unionName,
                variantTypes: [existingBase, incomingBase],
                variantTitleHints: [existing.schemaKey, incoming.schemaKey],
                variantCaseHints: [existing.schemaKey, incoming.schemaKey],
                variantDescriptions: [nil, nil],
                description: nil
            )
        }

        let requiredByAll = existing.requiredByAllInputs && incoming.requiredByAllInputs
        let shouldBeOptional = existingOptional || incomingOptional || !requiredByAll
        let finalType = shouldBeOptional ? .optional(mergedBase) : mergedBase

        return PropertyIR(
            schemaKey: existing.schemaKey,
            swiftName: existing.swiftName,
            type: finalType,
            requiredByAllInputs: requiredByAll,
            allowsNull: existing.allowsNull && incoming.allowsNull
        )
    }

    private mutating func schemaAllowsNull(
        _ schema: JSONValue,
        documentURL: URL,
        baseAlreadyApplied: Bool = false
    ) throws -> Bool {
        let schemaBaseURL =
            baseAlreadyApplied
            ? documentURL
            : try resolver.effectiveBaseURL(for: schema, from: documentURL)
        if schema.type == .bool {
            return schema.bool == true
        }
        if schema["type"].string == "null" {
            return true
        }
        if schema["type"].arrayValue.compactMap(\.string).contains("null") {
            return true
        }
        if (schema["const"].exists() && schema["const"].type == .null)
            || schema["enum"].arrayValue.contains(where: { $0.type == .null })
        {
            return true
        }
        if let ref = schema["$ref"].string {
            let referenceKey =
                URL(string: ref, relativeTo: schemaBaseURL)?.absoluteURL.absoluteString ?? ref
            if let cached = referenceNullability[referenceKey] {
                return cached
            }
            let resolved: ResolvedSchema
            if let cached = resolvedSchemasByReferenceURL[referenceKey] {
                resolved = cached
            } else {
                resolved = try resolver.resolve(ref: ref, from: schemaBaseURL)
                resolvedSchemasByReferenceURL[referenceKey] = resolved
            }
            let allowsNull = try schemaAllowsNull(
                resolved.json,
                documentURL: resolved.effectiveBaseURL,
                baseAlreadyApplied: true
            )
            referenceNullability[referenceKey] = allowsNull
            return allowsNull
        }
        for keyword in ["oneOf", "anyOf"] {
            if schema[keyword].arrayValue.contains(where: {
                (try? schemaAllowsNull($0, documentURL: schemaBaseURL)) == true
            }) {
                return true
            }
        }
        return false
    }

    private func unwrapOptional(_ type: SwiftType) -> SwiftType {
        if case .optional(let value) = type {
            return value
        }
        return type
    }

    private func isNullSchema(_ schema: JSONValue) -> Bool {
        if schema["type"].string == "null" {
            return true
        }
        if let types = schema["type"].array?.compactMap(\.string), types == ["null"] {
            return true
        }
        return false
    }

    private func detectUnionDiscriminatorKey(
        nonNullVariants: [(json: JSONValue, index: Int)], documentURL: URL
    ) throws -> String? {
        guard !nonNullVariants.isEmpty else { return nil }

        var maps: [[String: String]] = []
        for entry in nonNullVariants {
            guard
                let variantMap = try variantDiscriminatorLiterals(
                    entry.json, documentURL: documentURL), !variantMap.isEmpty
            else {
                return nil
            }
            maps.append(variantMap)
        }

        var intersection = Set(maps[0].keys)
        for map in maps.dropFirst() {
            intersection = intersection.intersection(map.keys)
        }
        guard !intersection.isEmpty else { return nil }

        for key in intersection.sorted() {
            var seen: Set<String> = []
            var unique = true
            for map in maps {
                guard let value = map[key], !seen.contains(value) else {
                    unique = false
                    break
                }
                seen.insert(value)
            }
            if unique {
                return key
            }
        }
        return nil
    }

    private func variantDiscriminatorLiteral(variant: JSONValue, key: String, documentURL: URL)
        throws
        -> String?
    {
        try variantDiscriminatorLiterals(variant, documentURL: documentURL)?[key]
    }

    private func variantDiscriminatorLiterals(_ variant: JSONValue, documentURL: URL) throws
        -> [String:
        String]?
    {
        let schema = try resolvedVariantSchemaIfRef(variant, documentURL: documentURL)
        guard schema["type"].string == "object" || !schema["properties"].dictionaryValue.isEmpty
        else { return nil }

        let required = Set(schema["required"].arrayValue.compactMap(\.string))
        var result: [String: String] = [:]
        for (key, property) in schema["properties"].dictionaryValue {
            guard required.contains(key) else { continue }
            guard property["type"].string == "string" else { continue }
            let values = property["enum"].arrayValue.compactMap(\.string)
            guard values.count == 1 else { continue }
            result[key] = values[0]
        }
        return result
    }

    private func resolvedVariantSchemaIfRef(_ variant: JSONValue, documentURL: URL) throws
        -> JSONValue
    {
        guard let ref = variant["$ref"].string else { return variant }
        return try resolver.resolve(ref: ref, from: documentURL).json
    }

    private func scalarEnumLiterals(_ schema: JSONValue) -> [EnumCaseLiteralIR]? {
        let values = schema["enum"].arrayValue
        guard !values.isEmpty else { return nil }

        var literals: [EnumCaseLiteralIR] = []
        literals.reserveCapacity(values.count)

        for value in values {
            if let typed = schema["type"].string {
                switch typed {
                case "string":
                    guard let string = value.string else { return nil }
                    literals.append(.string(string))
                    continue
                case "integer":
                    guard let int = value.int64 else { return nil }
                    literals.append(.int(int))
                    continue
                case "number":
                    guard let number = value.double else { return nil }
                    literals.append(.double(number))
                    continue
                case "boolean":
                    guard let boolean = value.bool else { return nil }
                    literals.append(.bool(boolean))
                    continue
                default:
                    return nil
                }
            }

            if let string = value.string {
                literals.append(.string(string))
            } else if let boolean = value.bool {
                literals.append(.bool(boolean))
            } else if let int = value.int64 {
                literals.append(.int(int))
            } else if let number = value.double {
                literals.append(.double(number))
            } else {
                return nil
            }
        }
        return literals
    }

    private func scalarLiteral(_ value: JSONValue) -> EnumCaseLiteralIR? {
        switch value.type {
        case .string:
            return value.string.map(EnumCaseLiteralIR.string)
        case .bool:
            return value.bool.map(EnumCaseLiteralIR.bool)
        case .number:
            if let int = value.int64, Double(int) == value.double {
                return .int(int)
            }
            return value.double.map(EnumCaseLiteralIR.double)
        case .null:
            return .null
        default:
            return nil
        }
    }

    private func literalIsCompatibleWithDeclaredType(
        _ literal: EnumCaseLiteralIR, schema: JSONValue
    )
        -> Bool
    {
        let declaredTypes: [String]
        if let type = schema["type"].string {
            declaredTypes = [type]
        } else {
            declaredTypes = schema["type"].arrayValue.compactMap(\.string)
        }
        guard !declaredTypes.isEmpty else { return true }
        return declaredTypes.contains { type in
            switch (type, literal) {
            case ("string", .string), ("integer", .int), ("number", .int), ("number", .double),
                ("boolean", .bool), ("null", .null):
                return true
            default:
                return false
            }
        }
    }

    private func singleScalarEnumCaseHint(_ literal: EnumCaseLiteralIR) -> String {
        switch literal {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return "null"
        }
    }

    private func fallbackEnumCaseName(for type: SwiftType, index: Int) -> String {
        // Primitive union naming policy:
        // - `.string`, `.integer`, `.number`, `.boolean` when unique
        // - numeric suffixes are added later by `nextEnumCaseName` on duplicates (`string2`, ...).
        switch type {
        case .string:
            return "string"
        case .int:
            return "integer"
        case .double:
            return "number"
        case .bool:
            return "boolean"
        case .named(let value):
            // `.named` is used for concrete Swift types inferred from schema (for example `Int64` via `"format": "int64"`).
            // We normalize known numeric/primitive Swift names back to schema-like case names.
            let lowered = value.lowercased()
            if lowered == "int64" || lowered == "int32" || lowered == "int" {
                return "integer"
            }
            // Treat `Double`/`Float` as JSONValue Schema `number` for case naming consistency.
            if lowered == "double" || lowered == "float" {
                return "number"
            }
            if lowered == "string" {
                return "string"
            }
            if lowered == "bool" || lowered == "boolean" {
                return "boolean"
            }
            return IdentifierSanitizer.enumCaseNameFromType(value, fallback: "valueCase\(index)")
        case .array:
            return "array"
        case .dictionary:
            return "object"
        case .null:
            return "null"
        case .existential:
            return "nullValue"
        case .optional(let wrapped):
            return fallbackEnumCaseName(for: wrapped, index: index)
        }
    }

    private func nextEnumCaseName(hint: String?, fallback: String, used: inout Set<String>)
        -> String
    {
        let raw = hint ?? fallback
        let fromTypeLikeHint = hint.map(isTypeLikeName) ?? false
        var candidate: String
        if fromTypeLikeHint {
            candidate = IdentifierSanitizer.enumCaseNameFromType(raw, fallback: fallback)
        } else {
            candidate = IdentifierSanitizer.enumCaseName(raw, fallback: fallback)
        }
        if candidate == "`null`" || candidate == "null" {
            candidate = "nullValue"
        }

        if !used.contains(candidate) {
            used.insert(candidate)
            return candidate
        }

        var index = 2
        while used.contains("\(candidate)\(index)") {
            index += 1
        }
        let unique = "\(candidate)\(index)"
        used.insert(unique)
        return unique
    }

    private mutating func nextGeneratedName(prefix: String) -> String {
        generatedNameCounter += 1
        if prefix.isEmpty {
            return "\(generatedNameCounter)"
        }
        return "\(prefix)\(generatedNameCounter)"
    }

    private mutating func beginProcessing(_ name: String) {
        processingTypeNames.insert(name)
        processingTypeStack.append(name)
    }

    private mutating func endProcessing(_ name: String) {
        processingTypeNames.remove(name)
        if processingTypeStack.last == name {
            processingTypeStack.removeLast()
        } else if let index = processingTypeStack.lastIndex(of: name) {
            processingTypeStack.remove(at: index)
        }
    }

    private mutating func markRecursiveCycle(endingAt name: String) {
        guard let index = processingTypeStack.firstIndex(of: name) else {
            recursiveTypeNames.insert(name)
            return
        }
        recursiveTypeNames.formUnion(processingTypeStack[index...])
    }

    private mutating func typeName(
        from title: String?,
        suggestedName: String,
        prefix: String,
        preferSuggestedName: Bool = false
    ) -> String {
        let fallback = nextGeneratedName(prefix: prefix)
        if preferSuggestedName {
            return qualifiedTypeName(from: suggestedName, fallback: fallback)
        }
        if title == nil, suggestedName.contains(".") {
            return qualifiedTypeName(from: suggestedName, fallback: fallback)
        }
        if let namespaced = namespacedTypeNameFromSuggestedContext(
            title: title, suggestedName: suggestedName, fallback: fallback)
        {
            return namespaced
        }
        let raw = title ?? suggestedName
        return IdentifierSanitizer.typeName(raw, fallback: fallback)
    }

    private func qualifiedTypeName(from raw: String, fallback: String) -> String {
        let parts = raw.split(separator: ".").map(String.init).filter { !$0.isEmpty }
        guard !parts.isEmpty else {
            return IdentifierSanitizer.typeName(raw, fallback: fallback)
        }
        let sanitized = parts.enumerated().map { index, part in
            IdentifierSanitizer.qualifiedComponent(part, fallback: "TypePart\(index + 1)")
        }
        return sanitized.joined(separator: ".")
    }

    private func namespacedTypeNameFromSuggestedContext(
        title: String?, suggestedName: String, fallback: String
    ) -> String? {
        guard let title = title.trimmedNonEmpty else { return nil }
        let suggestedParts = suggestedName.split(separator: ".").map(String.init).filter {
            !$0.isEmpty
        }
        guard suggestedParts.count > 1 else { return nil }
        let parent = suggestedParts.dropLast().joined(separator: ".")
        let leaf = IdentifierSanitizer.typeName(title, fallback: fallback)
        return qualifiedTypeName(from: "\(parent).\(leaf)", fallback: fallback)
    }

    private mutating func suggestedNestedTypeName(
        parent: String, key: String, fallbackPrefix: String
    ) -> String {
        let local = IdentifierSanitizer.typeName(
            key, fallback: nextGeneratedName(prefix: fallbackPrefix))
        return qualifiedTypeName(
            from: "\(parent).\(local)", fallback: nextGeneratedName(prefix: "TypePath"))
    }

    private mutating func definitionTypeName(path: [String], schema: JSONValue) -> String {
        let fallback = nextGeneratedName(prefix: "Definition")
        guard path.count >= 2 else {
            return IdentifierSanitizer.typeName(
                schema["title"].string ?? path.first ?? "Definition", fallback: fallback)
        }
        let root = IdentifierSanitizer.qualifiedComponent(path[0], fallback: "Root")
        let namespace = path.dropFirst().dropLast().enumerated().map { index, raw in
            IdentifierSanitizer.qualifiedComponent(String(raw), fallback: "ns\(index + 1)")
        }
        let leafFallback = IdentifierSanitizer.typeName(path.last ?? "Type", fallback: fallback)
        let leafRaw = schema["title"].string ?? path.last ?? leafFallback
        let leaf = IdentifierSanitizer.typeName(leafRaw, fallback: leafFallback)
        return ([root] + namespace + [leaf]).joined(separator: ".")
    }

    private func isSchemaCandidate(_ value: JSONValue) -> Bool {
        if value.type == .bool {
            return true
        }

        if value["$ref"].exists() || value["type"].exists() || value["enum"].array != nil
            || value["const"].exists()
        {
            return true
        }

        if value["properties"].dictionary != nil || value["required"].array != nil {
            return true
        }

        if value["allOf"].array != nil || value["anyOf"].array != nil || value["oneOf"].array != nil
        {
            return true
        }

        if value["items"].exists() || value["prefixItems"].exists()
            || value["additionalProperties"].exists()
        {
            return true
        }

        return false
    }

    private func typeNameForRef(
        ref: String,
        resolvedSchema: JSONValue,
        resolvedDocumentURL: URL,
        fallback: String
    ) -> String {
        let tokens = ref.decodedSchemaRefTokens
        if let first = tokens.first, (first == "definitions" || first == "$defs"), tokens.count >= 2
        {
            let rootNamespace =
                rootNamespaceByDocument[resolvedDocumentURL.standardizedFileURL]
                ?? IdentifierSanitizer.typeName(
                    resolvedDocumentURL.deletingPathExtension().lastPathComponent,
                    fallback: "Root"
                )
            return qualifiedDefinitionRefName(
                rootNamespace: rootNamespace,
                definitionPath: Array(tokens.dropFirst()),
                resolvedSchema: resolvedSchema,
                fallback: fallback
            )
        }

        let raw =
            resolvedSchema["title"].string ?? tokens.last ?? ref.lastDecodedSchemaRefToken
            ?? fallback
        return IdentifierSanitizer.typeName(raw, fallback: fallback)
    }

    private func qualifiedDefinitionRefName(
        rootNamespace: String,
        definitionPath: [String],
        resolvedSchema: JSONValue,
        fallback: String
    ) -> String {
        guard !definitionPath.isEmpty else {
            return IdentifierSanitizer.typeName(rootNamespace, fallback: fallback)
        }

        let root = IdentifierSanitizer.qualifiedComponent(rootNamespace, fallback: "Root")
        let namespace = definitionPath.dropLast().enumerated().map { index, raw in
            IdentifierSanitizer.qualifiedComponent(String(raw), fallback: "ns\(index + 1)")
        }
        let leafFallback = IdentifierSanitizer.typeName(
            definitionPath.last ?? "Type", fallback: fallback)
        let leafRaw = resolvedSchema["title"].string ?? definitionPath.last ?? leafFallback
        let leaf = IdentifierSanitizer.typeName(leafRaw, fallback: leafFallback)
        return ([root] + namespace + [leaf]).joined(separator: ".")
    }

    private func shouldPreferSuggestedNameForRef(_ ref: String) -> Bool {
        let tokens = ref.decodedSchemaRefTokens
        guard let first = tokens.first, (first == "definitions" || first == "$defs") else {
            return false
        }
        // For definitions refs we always prefer suggested qualified names to avoid title collisions.
        return tokens.count > 1
    }

    private func chooseDescription(_ lhs: String?, _ rhs: String?) -> String? {
        if let lhs = lhs.trimmedNonEmpty {
            return lhs
        }
        return rhs.trimmedNonEmpty
    }

    private func isTypeLikeName(_ value: String) -> Bool {
        value.isTypeLikeIdentifier
    }

    private mutating func documentRootNamespace(for document: SchemaDocument) -> String {
        let fallback = nextGeneratedName(prefix: "Root")
        let raw =
            document.json["title"].string ?? document.url.deletingPathExtension().lastPathComponent
        return IdentifierSanitizer.typeName(raw, fallback: fallback)
    }

    private func shouldTreatAllOfAsAlias(schema: JSONValue) -> Bool {
        let hasOwnObjectShape =
            !schema["properties"].dictionaryValue.isEmpty || schema["required"].array != nil
        let hasOwnCombinators = schema["anyOf"].array != nil || schema["oneOf"].array != nil
        let hasOwnType = schema["type"].exists()
        return !hasOwnObjectShape && !hasOwnCombinators && !hasOwnType
    }

    private func shouldMaterializeRootType(for schema: JSONValue) -> Bool {
        let hasDefinitions =
            !schema["$defs"].dictionaryValue.isEmpty
            || !schema["definitions"].dictionaryValue.isEmpty
        guard hasDefinitions else {
            return true
        }

        let hasProperties = !schema["properties"].dictionaryValue.isEmpty
        let hasRequired = schema["required"].array != nil
        let hasCombinators =
            schema["allOf"].array != nil || schema["anyOf"].array != nil
            || schema["oneOf"].array != nil
        let hasArrayShape = schema["items"].exists() || schema["prefixItems"].exists()
        let hasEnum = schema["enum"].array != nil
        let hasConst = schema["const"].exists()
        let hasRef = schema["$ref"].exists()
        let hasAdditional = schema["additionalProperties"].exists()
        let explicitType = schema["type"].string

        // If root is only a definitions holder, emit namespace container enum via emitter, not a Codable model type.
        let isContainerObject =
            (explicitType == nil || explicitType == "object")
            && !hasProperties
            && !hasRequired
            && !hasCombinators
            && !hasArrayShape
            && !hasEnum
            && !hasConst
            && !hasRef
            && !hasAdditional
        return !isContainerObject
    }
}
