import Foundation
import SwiftSyntax
import SwiftSyntaxBuilder

struct SwiftEmitter {
    let options: GenerationOptions
    private let unknownValueTypePlaceholder = "__UNKNOWN_VALUE_TYPE__"
    private let unknownNullTypePlaceholder = "__UNKNOWN_NULL_TYPE__"

    private struct DeclNode {
        var declaration: TypeDeclIR?
        var children: [String: DeclNode] = [:]
    }

    func emitFile(declarations: [TypeDeclIR], typeAliases: [TypeAliasIR] = []) throws -> String {
        let helperNames = helperTypeNames(declarations: declarations, typeAliases: typeAliases)

        // Shared helper emitted once, at file end, when schemas contain unknown/untyped values.
        let requiresUnknownValue = declarations.contains { declarationContainsExistential($0) }
        let requiresUnknownNull = declarations.contains { declarationContainsNull($0) }
        let renderedDeclarations = renderTopLevelDeclarations(declarations)

        let source = SourceFileSyntax {
            ImportDeclSyntax(
                path: .init([ImportPathComponentSyntax(name: .identifier("Foundation"))]))
            DeclSyntax("")

            for declaration in renderedDeclarations {
                DeclSyntax(stringLiteral: declaration)
                DeclSyntax("")
            }

            for alias in typeAliases.sorted(by: { $0.name < $1.name }) {
                DeclSyntax(stringLiteral: "public typealias \(alias.name) = \(alias.target)")
                DeclSyntax("")
            }

            if requiresUnknownValue {
                DeclSyntax(stringLiteral: renderGlobalUnknownValueType())
                if requiresUnknownNull {
                    DeclSyntax("")
                }
            }

            if requiresUnknownNull {
                DeclSyntax(stringLiteral: renderGlobalUnknownNullType())
            }
        }
        let formatted = source.formatted()
        let rewritten = PlaceholderIdentifierRewriter(
            replacements: [
                unknownValueTypePlaceholder: helperNames.value,
                unknownNullTypePlaceholder: helperNames.null,
            ]
        ).rewrite(Syntax(formatted))
        return rewritten.description
    }

    private func renderTopLevelDeclarations(_ declarations: [TypeDeclIR]) -> [String] {
        var root = DeclNode()
        for declaration in declarations {
            insert(declaration: declaration, into: &root)
        }
        return root.children.keys.sorted().compactMap { key in
            guard let node = root.children[key] else { return nil }
            return renderNode(name: key, node: node)
        }
    }

    private func insert(declaration: TypeDeclIR, into root: inout DeclNode) {
        let components = declaration.name.split(separator: ".").map(String.init)
        guard !components.isEmpty else { return }
        insert(declaration: declaration, components: components, index: 0, into: &root)
    }

    private func insert(
        declaration: TypeDeclIR, components: [String], index: Int, into node: inout DeclNode
    ) {
        let key = components[index]
        var child = node.children[key] ?? DeclNode()
        if index == components.count - 1 {
            child.declaration = declaration
        } else {
            insert(declaration: declaration, components: components, index: index + 1, into: &child)
        }
        node.children[key] = child
    }

    private func renderNode(name: String, node: DeclNode) -> String {
        let nested = node.children.keys.sorted().compactMap { key -> String? in
            guard let child = node.children[key] else { return nil }
            return renderNode(name: key, node: child)
        }

        if let declaration = node.declaration {
            switch declaration {
            case .structDecl(let value):
                let local = StructIR(
                    name: name,
                    description: value.description,
                    properties: value.properties,
                    isReferenceType: value.isReferenceType,
                    additionalProperties: value.additionalProperties
                )
                return renderStruct(local, nestedDeclarations: nested)
            case .enumDecl(let value):
                let local = EnumIR(
                    name: name,
                    description: value.description,
                    discriminatorKey: value.discriminatorKey,
                    cases: value.cases,
                    unionKind: value.unionKind,
                    isIndirect: value.isIndirect
                )
                return renderEnum(local, nestedDeclarations: nested)
            case .tupleDecl(let value):
                let local = TupleIR(
                    name: name,
                    description: value.description,
                    elements: value.elements,
                    additionalElementType: value.additionalElementType,
                    maximumCount: value.maximumCount
                )
                return renderTuple(local, nestedDeclarations: nested)
            case .rawStringEnumDecl(let value):
                let local = RawEnumIR(
                    name: name, description: value.description, cases: value.cases)
                return renderRawStringEnum(local, nestedDeclarations: nested)
            case .typeAliasDecl(let value):
                return "public typealias \(name) = \(renderType(value.target, topLevel: true))"
            }
        }

        // Synthetic namespace container for dotted declarations with missing explicit parent declaration.
        var lines: [String] = []
        lines.append("public enum \(name) {")
        if !nested.isEmpty {
            lines.append("")
            for (index, declaration) in nested.enumerated() {
                lines.append(indent(declaration, by: "    "))
                if index < nested.count - 1 {
                    lines.append("")
                }
            }
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    private func renderStruct(_ value: StructIR, nestedDeclarations: [String]) -> String {
        let additionalPropertyName = additionalPropertiesPropertyName(for: value)
        let needsCustomCoding =
            value.additionalProperties != .ignored
            || value.properties.contains(where: { $0.type.isOptional })
        let needsCodingKeys = value.properties.contains(where: \.needsCodingKey)

        var lines: [String] = []
        lines.append(contentsOf: documentationLines(value.description, indent: ""))
        let declarationKind = value.isReferenceType ? "final class" : "struct"
        lines.append(
            "public \(declarationKind) \(value.name): Codable\(options.conformancesSuffix) {")

        for property in value.properties {
            lines.append(
                "    public let \(property.swiftName): \(renderType(property.type, topLevel: true))"
            )
        }
        if case .captured(let additionalType) = value.additionalProperties {
            lines.append(
                "    public let \(additionalPropertyName): [String: \(renderType(additionalType, topLevel: false))]"
            )
        }

        lines.append("")
        if value.properties.isEmpty {
            lines.append("    public init() {}")
        } else {
            var parameterParts = value.properties
                .map {
                    let defaultValue = $0.type.isOptional && !$0.requiredByAllInputs ? " = nil" : ""
                    return "\($0.swiftName): \(renderType($0.type, topLevel: true))\(defaultValue)"
                }
            if case .captured(let additionalType) = value.additionalProperties {
                parameterParts.append(
                    "\(additionalPropertyName): [String: \(renderType(additionalType, topLevel: false))] = [:]"
                )
            }
            let parameters = parameterParts.joined(separator: ", ")
            lines.append("    public init(\(parameters)) {")
            for property in value.properties {
                lines.append("        self.\(property.swiftName) = \(property.swiftName)")
            }
            if case .captured = value.additionalProperties {
                lines.append("        self.\(additionalPropertyName) = \(additionalPropertyName)")
            }
            lines.append("    }")
        }

        if value.properties.isEmpty, case .captured(let additionalType) = value.additionalProperties
        {
            lines.removeLast()
            lines.append(
                "    public init(\(additionalPropertyName): [String: \(renderType(additionalType, topLevel: false))] = [:]) {"
            )
            lines.append("        self.\(additionalPropertyName) = \(additionalPropertyName)")
            lines.append("    }")
        }

        if needsCustomCoding {
            lines.append(
                contentsOf: renderObjectCoding(
                    value, additionalPropertyName: additionalPropertyName))
        }

        if !nestedDeclarations.isEmpty {
            lines.append("")
            for (index, declaration) in nestedDeclarations.enumerated() {
                lines.append(indent(declaration, by: "    "))
                if index < nestedDeclarations.count - 1 {
                    lines.append("")
                }
            }
        }

        if needsCodingKeys {
            // Emit `CodingKeys` only when sanitized Swift property names differ from schema keys.
            lines.append("")
            lines.append("    enum CodingKeys: String, CodingKey {")
            for property in value.properties {
                if property.needsCodingKey {
                    lines.append("        case \(property.swiftName) = \"\(property.schemaKey)\"")
                } else {
                    lines.append("        case \(property.swiftName)")
                }
            }
            lines.append("    }")
        }

        lines.append("}")
        return lines.joined(separator: "\n")
    }

    private func additionalPropertiesPropertyName(for value: StructIR) -> String {
        let usedNames = Set(
            value.properties.map { $0.swiftName.replacingOccurrences(of: "`", with: "") })
        var candidate = "additionalProperties"
        while usedNames.contains(candidate) {
            candidate += "Storage"
        }
        return candidate
    }

    private func renderObjectCoding(_ value: StructIR, additionalPropertyName: String) -> [String] {
        var lines: [String] = []
        lines.append("")
        lines.append("    public init(from decoder: Decoder) throws {")
        lines.append(
            "        let container = try decoder.container(keyedBy: _JSONSchemaGenCodingKey.self)")
        for property in value.properties {
            let keyLiteral = escapedStringLiteral(property.schemaKey)
            let keyVariable = "\(property.swiftName.replacingOccurrences(of: "`", with: ""))Key"
            lines.append("        let \(keyVariable) = _JSONSchemaGenCodingKey(\"\(keyLiteral)\")")
            if case .optional(let wrapped) = property.type {
                if property.requiredByAllInputs {
                    lines.append("        guard container.contains(\(keyVariable)) else {")
                    lines.append(
                        "            throw DecodingError.keyNotFound(\(keyVariable), .init(codingPath: decoder.codingPath, debugDescription: \"Missing required key \(keyLiteral)\"))"
                    )
                    lines.append("        }")
                }
                if property.allowsNull {
                    lines.append(
                        "        self.\(property.swiftName) = try container.decodeIfPresent(\(renderType(wrapped, topLevel: false)).self, forKey: \(keyVariable))"
                    )
                } else {
                    lines.append(
                        "        self.\(property.swiftName) = container.contains(\(keyVariable)) ? try container.decode(\(renderType(wrapped, topLevel: false)).self, forKey: \(keyVariable)) : nil"
                    )
                }
            } else {
                lines.append(
                    "        self.\(property.swiftName) = try container.decode(\(renderType(property.type, topLevel: false)).self, forKey: \(keyVariable))"
                )
            }
        }

        let knownKeys = value.properties
            .map { "\"\(escapedStringLiteral($0.schemaKey))\"" }
            .joined(separator: ", ")
        switch value.additionalProperties {
        case .ignored:
            break
        case .captured(let additionalType):
            lines.append("        let knownKeys: Set<String> = [\(knownKeys)]")
            lines.append(
                "        var additionalProperties: [String: \(renderType(additionalType, topLevel: false))] = [:]"
            )
            lines.append(
                "        for key in container.allKeys where !knownKeys.contains(key.stringValue) {")
            lines.append(
                "            additionalProperties[key.stringValue] = try container.decode(\(renderType(additionalType, topLevel: false)).self, forKey: key)"
            )
            lines.append("        }")
            lines.append("        self.\(additionalPropertyName) = additionalProperties")
        case .forbidden:
            lines.append("        let knownKeys: Set<String> = [\(knownKeys)]")
            lines.append(
                "        if let unexpected = container.allKeys.first(where: { !knownKeys.contains($0.stringValue) }) {"
            )
            lines.append(
                "            throw DecodingError.dataCorruptedError(forKey: unexpected, in: container, debugDescription: \"Additional property is forbidden\")"
            )
            lines.append("        }")
        }
        lines.append("    }")
        lines.append("")
        lines.append("    public func encode(to encoder: Encoder) throws {")
        lines.append(
            "        var container = encoder.container(keyedBy: _JSONSchemaGenCodingKey.self)")
        for property in value.properties {
            let keyLiteral = escapedStringLiteral(property.schemaKey)
            if case .optional = property.type {
                if property.requiredByAllInputs && property.allowsNull {
                    lines.append(
                        "        try container.encode(\(property.swiftName), forKey: _JSONSchemaGenCodingKey(\"\(keyLiteral)\"))"
                    )
                } else {
                    lines.append(
                        "        try container.encodeIfPresent(\(property.swiftName), forKey: _JSONSchemaGenCodingKey(\"\(keyLiteral)\"))"
                    )
                }
            } else {
                lines.append(
                    "        try container.encode(\(property.swiftName), forKey: _JSONSchemaGenCodingKey(\"\(keyLiteral)\"))"
                )
            }
        }
        if case .captured = value.additionalProperties {
            lines.append("        for (key, value) in \(additionalPropertyName) {")
            lines.append(
                "            try container.encode(value, forKey: _JSONSchemaGenCodingKey(key))")
            lines.append("        }")
        }
        lines.append("    }")
        lines.append("")
        lines.append("    private struct _JSONSchemaGenCodingKey: CodingKey {")
        lines.append("        let stringValue: String")
        lines.append("        let intValue: Int?")
        lines.append(
            "        init(_ stringValue: String) { self.stringValue = stringValue; self.intValue = nil }"
        )
        lines.append("        init?(stringValue: String) { self.init(stringValue) }")
        lines.append(
            "        init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }"
        )
        lines.append("    }")
        return lines
    }

    private func renderEnum(_ value: EnumIR, nestedDeclarations: [String]) -> String {
        let discriminator = discriminatorSpec(for: value)
        var lines: [String] = []
        lines.append(contentsOf: documentationLines(value.description, indent: ""))
        let indirectPrefix = value.isIndirect ? "indirect " : ""
        lines.append(
            "public \(indirectPrefix)enum \(value.name): Codable\(options.conformancesSuffix) {")
        for enumCase in value.cases {
            lines.append(contentsOf: documentationLines(enumCase.description, indent: "    "))
            if let associated = enumCase.associatedType {
                lines.append(
                    "    case \(enumCase.name)(\(renderType(associated, topLevel: false)))")
            } else if enumCase.literal != nil {
                lines.append("    case \(enumCase.name)")
            } else {
                lines.append("    case \(enumCase.name)")
            }
        }

        if let discriminator {
            lines.append("")
            lines.append(
                "    public enum \(discriminator.typeName): String, Codable\(options.conformancesSuffix) {"
            )
            for item in discriminator.cases {
                lines.append(
                    "        case \(item.enumCaseName) = \"\(escapedStringLiteral(item.rawLiteral))\""
                )
            }
            lines.append("    }")
            lines.append("")
            lines.append("")
            lines.append("    private enum DiscriminatorCodingKeys: String, CodingKey {")
            lines.append("        case discriminator = \"\(discriminator.key)\"")
            lines.append("    }")
        }

        if !nestedDeclarations.isEmpty {
            lines.append("")
            for declaration in nestedDeclarations {
                lines.append(indent(declaration, by: "    "))
                lines.append("")
            }
            if lines.last == "" {
                lines.removeLast()
            }
        }

        lines.append("")
        // Any-of selects the first decodable branch. Non-discriminated one-of
        // counts decodable branches and rejects ambiguous payloads.
        lines.append("    public init(from decoder: Decoder) throws {")
        lines.append("        let container = try decoder.singleValueContainer()")
        if let discriminator {
            lines.append(
                "        if let keyed = try? decoder.container(keyedBy: DiscriminatorCodingKeys.self), let discriminator = try? keyed.decode(\(discriminator.typeName).self, forKey: .discriminator) {"
            )
            lines.append("            switch discriminator {")
            for item in discriminator.cases {
                lines.append("            case .\(item.enumCaseName):")
                if let associated = item.parentCase.associatedType {
                    lines.append(
                        "                if let value = try? container.decode(\(renderType(associated, topLevel: false)).self) {"
                    )
                    lines.append("                    self = .\(item.parentCase.name)(value)")
                    lines.append("                    return")
                    lines.append("                }")
                } else {
                    lines.append("                self = .\(item.parentCase.name)")
                    lines.append("                return")
                }
            }
            lines.append("            }")
            lines.append("        }")
        }
        let requiresExclusiveMatch =
            value.unionKind == .oneOf && discriminator == nil && value.cases.count > 1
        if requiresExclusiveMatch {
            lines.append("        var match: Self?")
            lines.append("        var matchCount = 0")
        }
        for enumCase in value.cases {
            let matchedLines: [String]
            if requiresExclusiveMatch {
                matchedLines = [
                    "match = Self.\(enumCase.name)MATCH_VALUE", "matchCount += 1",
                ]
            } else {
                matchedLines = ["self = .\(enumCase.name)MATCH_VALUE", "return"]
            }

            if let associated = enumCase.associatedType {
                if case .optional(let wrapped) = associated {
                    lines.append("        if container.decodeNil() {")
                    for matched in matchedLines {
                        lines.append(
                            "            \(matched.replacingOccurrences(of: "MATCH_VALUE", with: "(nil)"))"
                        )
                    }
                    lines.append(
                        "        } else if let value = try? container.decode(\(renderType(wrapped, topLevel: false)).self) {"
                    )
                    for matched in matchedLines {
                        lines.append(
                            "            \(matched.replacingOccurrences(of: "MATCH_VALUE", with: "(value)"))"
                        )
                    }
                    lines.append("        }")
                } else {
                    lines.append(
                        "        if let value = try? container.decode(\(renderType(associated, topLevel: false)).self) {"
                    )
                    for matched in matchedLines {
                        lines.append(
                            "            \(matched.replacingOccurrences(of: "MATCH_VALUE", with: "(value)"))"
                        )
                    }
                    lines.append("        }")
                }
            } else if let literal = enumCase.literal {
                if case .null = literal {
                    lines.append("        if container.decodeNil() {")
                } else {
                    let literalType = literalTypeName(literal)
                    let literalValue = literalExpression(literal)
                    lines.append(
                        "        if let value = try? container.decode(\(literalType).self), value == \(literalValue) {"
                    )
                }
                for matched in matchedLines {
                    lines.append(
                        "            \(matched.replacingOccurrences(of: "MATCH_VALUE", with: ""))")
                }
                lines.append("        }")
            } else {
                lines.append("        if container.decodeNil() {")
                for matched in matchedLines {
                    lines.append(
                        "            \(matched.replacingOccurrences(of: "MATCH_VALUE", with: ""))")
                }
                lines.append("        }")
            }
        }
        if requiresExclusiveMatch {
            lines.append("        guard matchCount == 1, let match else {")
            lines.append(
                "            throw DecodingError.typeMismatch(\(value.name).self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: \"Expected exactly one matching oneOf branch for \(value.name)\"))"
            )
            lines.append("        }")
            lines.append("        self = match")
        } else {
            lines.append(
                "        throw DecodingError.typeMismatch(\(value.name).self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: \"Unsupported union shape for \(value.name)\"))"
            )
        }
        lines.append("    }")
        lines.append("")
        lines.append("    public func encode(to encoder: Encoder) throws {")
        lines.append("        var container = encoder.singleValueContainer()")
        lines.append("        switch self {")
        for enumCase in value.cases {
            if enumCase.associatedType != nil {
                lines.append("        case .\(enumCase.name)(let value):")
                lines.append("            try container.encode(value)")
            } else if let literal = enumCase.literal {
                lines.append("        case .\(enumCase.name):")
                if case .null = literal {
                    lines.append("            try container.encodeNil()")
                } else {
                    lines.append("            try container.encode(\(literalExpression(literal)))")
                }
            } else {
                lines.append("        case .\(enumCase.name):")
                lines.append("            try container.encodeNil()")
            }
        }
        lines.append("        }")
        lines.append("    }")
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    private struct DiscriminatorEnumSpec {
        struct Item {
            let rawLiteral: String
            let enumCaseName: String
            let parentCase: EnumCaseIR
        }

        let key: String
        let typeName: String
        let cases: [Item]
    }

    private func discriminatorSpec(for value: EnumIR) -> DiscriminatorEnumSpec? {
        guard let key = value.discriminatorKey else { return nil }

        var usedNames: Set<String> = []
        var items: [DiscriminatorEnumSpec.Item] = []
        for parentCase in value.cases {
            guard case .string(let literal)? = parentCase.literal else { continue }
            var caseName = IdentifierSanitizer.enumCaseName(
                literal, fallback: "value\(items.count + 1)")
            if usedNames.contains(caseName) {
                var suffix = 2
                while usedNames.contains("\(caseName)\(suffix)") {
                    suffix += 1
                }
                caseName = "\(caseName)\(suffix)"
            }
            usedNames.insert(caseName)
            items.append(.init(rawLiteral: literal, enumCaseName: caseName, parentCase: parentCase))
        }

        guard items.count >= 2 else { return nil }
        let keyTypeName = IdentifierSanitizer.typeName(key, fallback: "Discriminator")
        let typeName: String
        if keyTypeName == "Type" {
            typeName = "TypeDiscriminator"
        } else {
            typeName = keyTypeName
        }
        return DiscriminatorEnumSpec(key: key, typeName: typeName, cases: items)
    }

    private func renderRawStringEnum(_ value: RawEnumIR, nestedDeclarations: [String]) -> String {
        var lines: [String] = []
        lines.append(contentsOf: documentationLines(value.description, indent: ""))
        lines.append("public enum \(value.name): String, Codable\(options.conformancesSuffix) {")
        for enumCase in value.cases {
            lines.append(
                "    case \(enumCase.name) = \"\(escapedStringLiteral(enumCase.rawValue))\"")
        }
        if !nestedDeclarations.isEmpty {
            lines.append("")
            for (index, declaration) in nestedDeclarations.enumerated() {
                lines.append(indent(declaration, by: "    "))
                if index < nestedDeclarations.count - 1 {
                    lines.append("")
                }
            }
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    func indent(_ value: String, by prefix: String) -> String {
        value
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "\(prefix)\($0)" }
            .joined(separator: "\n")
    }

    private func renderGlobalUnknownValueType() -> String {
        var lines: [String] = []
        lines.append(
            "/// Represents arbitrary values for schema fields without explicit type information.")
        lines.append(
            "public enum \(unknownValueTypePlaceholder): Codable\(options.conformancesSuffix) {")
        lines.append("    case string(String)")
        lines.append("    case integer(Int64)")
        lines.append("    case number(Double)")
        lines.append("    case boolean(Bool)")
        lines.append("    case object([String: \(unknownValueTypePlaceholder)])")
        lines.append("    case array([\(unknownValueTypePlaceholder)])")
        lines.append("    case null")
        lines.append("")
        lines.append("    public init(from decoder: Decoder) throws {")
        // Dynamic decoding order: scalar -> object -> array -> null.
        lines.append("        let container = try decoder.singleValueContainer()")
        lines.append("        if container.decodeNil() { self = .null; return }")
        lines.append(
            "        if let value = try? container.decode(String.self) { self = .string(value); return }"
        )
        lines.append(
            "        if let value = try? container.decode(Int64.self) { self = .integer(value); return }"
        )
        lines.append(
            "        if let value = try? container.decode(Double.self) { self = .number(value); return }"
        )
        lines.append(
            "        if let value = try? container.decode(Bool.self) { self = .boolean(value); return }"
        )
        lines.append(
            "        if let value = try? container.decode([String: \(unknownValueTypePlaceholder)].self) { self = .object(value); return }"
        )
        lines.append(
            "        if let value = try? container.decode([\(unknownValueTypePlaceholder)].self) { self = .array(value); return }"
        )
        lines.append(
            "        throw DecodingError.typeMismatch(\(unknownValueTypePlaceholder).self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: \"Unsupported untyped value\"))"
        )
        lines.append("    }")
        lines.append("")
        lines.append("    public func encode(to encoder: Encoder) throws {")
        lines.append("        var container = encoder.singleValueContainer()")
        lines.append("        switch self {")
        lines.append("        case .string(let value): try container.encode(value)")
        lines.append("        case .integer(let value): try container.encode(value)")
        lines.append("        case .number(let value): try container.encode(value)")
        lines.append("        case .boolean(let value): try container.encode(value)")
        lines.append("        case .object(let value): try container.encode(value)")
        lines.append("        case .array(let value): try container.encode(value)")
        lines.append("        case .null: try container.encodeNil()")
        lines.append("        }")
        lines.append("    }")
        lines.append("")
        lines.append("    public subscript(key: String) -> \(unknownValueTypePlaceholder) {")
        lines.append("        guard case .object(let object) = self else { return .null }")
        lines.append("        return object[key] ?? .null")
        lines.append("    }")
        lines.append("")
        lines.append("    public subscript(index: Int) -> \(unknownValueTypePlaceholder) {")
        lines.append(
            "        guard case .array(let array) = self, array.indices.contains(index) else { return .null }"
        )
        lines.append("        return array[index]")
        lines.append("    }")
        lines.append("")
        lines.append("    public var stringValue: String? {")
        lines.append("        switch self {")
        lines.append("        case .string(let value): return value")
        lines.append("        case .integer(let value): return String(value)")
        lines.append("        case .number(let value): return String(value)")
        lines.append("        case .boolean(let value): return value ? \"true\" : \"false\"")
        lines.append("        case .object: return nil")
        lines.append("        case .array: return nil")
        lines.append("        case .null: return nil")
        lines.append("        }")
        lines.append("    }")
        lines.append("")
        lines.append("    public var intValue: Int? {")
        lines.append("        switch self {")
        lines.append("        case .integer(let value): return Int(exactly: value)")
        lines.append("        case .number(let value): return Int(value)")
        lines.append("        case .string(let value): return Int(value)")
        lines.append("        case .boolean: return nil")
        lines.append("        case .object: return nil")
        lines.append("        case .array: return nil")
        lines.append("        case .null: return nil")
        lines.append("        }")
        lines.append("    }")
        lines.append("")
        lines.append("    public var doubleValue: Double? {")
        lines.append("        switch self {")
        lines.append("        case .number(let value): return value")
        lines.append("        case .integer(let value): return Double(value)")
        lines.append("        case .string(let value): return Double(value)")
        lines.append("        case .boolean: return nil")
        lines.append("        case .object: return nil")
        lines.append("        case .array: return nil")
        lines.append("        case .null: return nil")
        lines.append("        }")
        lines.append("    }")
        lines.append("")
        lines.append("    public var boolValue: Bool? {")
        lines.append("        switch self {")
        lines.append("        case .boolean(let value): return value")
        lines.append("        case .integer(let value): return value != 0")
        lines.append("        case .number(let value): return value != 0")
        lines.append("        case .string: return nil")
        lines.append("        case .object: return nil")
        lines.append("        case .array: return nil")
        lines.append("        case .null: return nil")
        lines.append("        }")
        lines.append("    }")
        lines.append("")
        lines.append("    public var arrayValue: [\(unknownValueTypePlaceholder)]? {")
        lines.append("        if case .array(let value) = self { return value }")
        lines.append("        return nil")
        lines.append("    }")
        lines.append("")
        lines.append("    public var dictionaryValue: [String: \(unknownValueTypePlaceholder)]? {")
        lines.append("        if case .object(let value) = self { return value }")
        lines.append("        return nil")
        lines.append("    }")
        lines.append("")
        lines.append("    public var isNull: Bool {")
        lines.append("        if case .null = self { return true }")
        lines.append("        return false")
        lines.append("    }")
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    private func renderGlobalUnknownNullType() -> String {
        [
            "/// A value that can only decode/encode null.",
            "public enum \(unknownNullTypePlaceholder): Codable\(options.conformancesSuffix) {",
            "    case null",
            "",
            "    public init(from decoder: Decoder) throws {",
            "        let container = try decoder.singleValueContainer()",
            "        guard container.decodeNil() else {",
            "            throw DecodingError.typeMismatch(",
            "                \(unknownNullTypePlaceholder).self,",
            "                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: \"Expected null\")",
            "            )",
            "        }",
            "        self = .null",
            "    }",
            "",
            "    public func encode(to encoder: Encoder) throws {",
            "        var container = encoder.singleValueContainer()",
            "        try container.encodeNil()",
            "    }",
            "}",
        ].joined(separator: "\n")
    }

    func renderType(_ type: SwiftType, topLevel: Bool) -> String {
        switch type {
        case .string:
            return "String"
        case .int:
            return "Int"
        case .double:
            return "Double"
        case .bool:
            return "Bool"
        case .null:
            return unknownNullTypePlaceholder
        case .named(let name):
            return name
        case .array(let item):
            return "[\(renderType(item, topLevel: false))]"
        case .dictionary(let value):
            return "[String: \(renderType(value, topLevel: false))]"
        case .existential:
            // Unknown/untyped schema values map to a generated concrete value model.
            return unknownValueTypePlaceholder
        case .optional(let wrapped):
            let inner = renderType(wrapped, topLevel: topLevel)
            if inner.hasPrefix("any ") {
                return "(\(inner))?"
            }
            return "\(inner)?"
        }
    }

    private func declarationContainsExistential(_ declaration: TypeDeclIR) -> Bool {
        switch declaration {
        case .structDecl(let value):
            let additionalContainsExistential: Bool
            if case .captured(let type) = value.additionalProperties {
                additionalContainsExistential = containsExistential(type)
            } else {
                additionalContainsExistential = false
            }
            return value.properties.contains(where: { containsExistential($0.type) })
                || additionalContainsExistential
        case .enumDecl(let value):
            return value.cases.contains(where: { containsExistential($0.associatedType) })
        case .tupleDecl(let value):
            return value.elements.contains(where: { containsExistential($0.type) })
                || containsExistential(value.additionalElementType)
        case .rawStringEnumDecl:
            return false
        case .typeAliasDecl(let value):
            return containsExistential(value.target)
        }
    }

    private func containsExistential(_ type: SwiftType?) -> Bool {
        guard let type else { return false }
        switch type {
        case .existential:
            return true
        case .null:
            return false
        case .array(let item):
            return containsExistential(item)
        case .dictionary(let value):
            return containsExistential(value)
        case .optional(let wrapped):
            return containsExistential(wrapped)
        default:
            return false
        }
    }

    private func declarationContainsNull(_ declaration: TypeDeclIR) -> Bool {
        switch declaration {
        case .structDecl(let value):
            let additionalContainsNull: Bool
            if case .captured(let type) = value.additionalProperties {
                additionalContainsNull = containsNull(type)
            } else {
                additionalContainsNull = false
            }
            return value.properties.contains(where: { containsNull($0.type) })
                || additionalContainsNull
        case .enumDecl(let value):
            return value.cases.contains(where: { containsNull($0.associatedType) })
        case .tupleDecl(let value):
            return value.elements.contains(where: { containsNull($0.type) })
                || containsNull(value.additionalElementType)
        case .rawStringEnumDecl:
            return false
        case .typeAliasDecl(let value):
            return containsNull(value.target)
        }
    }

    private func containsNull(_ type: SwiftType?) -> Bool {
        guard let type else { return false }
        switch type {
        case .null:
            return true
        case .array(let item):
            return containsNull(item)
        case .dictionary(let value):
            return containsNull(value)
        case .optional(let wrapped):
            return containsNull(wrapped)
        default:
            return false
        }
    }

    private func helperTypeNames(declarations: [TypeDeclIR], typeAliases: [TypeAliasIR]) -> (
        value: String, null: String
    ) {
        var occupiedNames: Set<String> = []
        for declaration in declarations {
            let simpleName =
                declaration.name.split(separator: ".").last.map(String.init) ?? declaration.name
            occupiedNames.insert(simpleName)
        }
        for alias in typeAliases {
            let simpleName = alias.name.split(separator: ".").last.map(String.init) ?? alias.name
            occupiedNames.insert(simpleName)
        }

        if occupiedNames.contains("AnyValue") || occupiedNames.contains("NullValue") {
            return ("JSONValue", "JSONNull")
        }
        return ("AnyValue", "NullValue")
    }

    private func literalTypeName(_ literal: EnumCaseLiteralIR) -> String {
        switch literal {
        case .string:
            return "String"
        case .int:
            return "Int64"
        case .double:
            return "Double"
        case .bool:
            return "Bool"
        case .null:
            return "Never"
        }
    }

    private func literalExpression(_ literal: EnumCaseLiteralIR) -> String {
        switch literal {
        case .string(let value):
            return "\"\(escapedStringLiteral(value))\""
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return "nil"
        }
    }

    private func escapedStringLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    func documentationLines(_ documentation: String?, indent: String) -> [String] {
        guard let documentation else { return [] }
        let trimmed = documentation.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return []
        }

        return
            trimmed
            .split(whereSeparator: \.isNewline)
            .map { "\(indent)/// \($0.trimmingCharacters(in: .whitespaces))" }
    }
}

private final class PlaceholderIdentifierRewriter: SyntaxRewriter {
    private let replacements: [String: String]

    init(replacements: [String: String]) {
        self.replacements = replacements
    }

    override func visit(_ token: TokenSyntax) -> TokenSyntax {
        guard case .identifier(let identifier) = token.tokenKind,
            let replacement = replacements[identifier]
        else {
            return token
        }
        return token.with(\.tokenKind, .identifier(replacement))
    }
}
