import Foundation

struct IdentifierSanitizer {
    private static let swiftKeywords: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import",
        "init",
        "inout", "internal", "let", "open", "operator", "private", "protocol", "public", "rethrows",
        "static", "struct", "subscript", "typealias", "var", "break", "case", "continue", "default",
        "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return",
        "switch",
        "where", "while", "as", "Any", "catch", "false", "is", "nil", "super", "self", "Self",
        "throw",
        "throws", "true", "try", "actor", "await", "async", "some", "any",
    ]

    static func typeName(_ raw: String, fallback: String) -> String {
        let tokens = split(raw)
        let base = tokens.map(capitalize).joined()
        let value = base.isEmpty ? fallback : base
        // `Foo.Type` is metatype syntax in Swift; a nested member named exactly `Type` is invalid.
        if value == "Type" {
            return "`Type`"
        }
        if isSwiftIdentifier(value), !swiftKeywords.contains(value) {
            return value
        }
        let prefixed = "Type\(capitalize(value))"
        return isSwiftIdentifier(prefixed) ? prefixed : fallback
    }

    static func propertyName(_ raw: String, fallback: String) -> String {
        let tokens = split(raw)
        if tokens.isEmpty {
            return fallback
        }
        let first = lowercasedFirst(tokens.first ?? fallback)
        let tail = tokens.dropFirst().map(capitalize).joined()
        let value = first + tail
        return escapedIdentifier(value, fallback: fallback)
    }

    static func enumCaseName(_ raw: String, fallback: String) -> String {
        let tokens = split(raw)
        let base: String
        if tokens.isEmpty {
            base = fallback
        } else {
            base =
                lowercasedFirst(tokens.first ?? fallback)
                + tokens.dropFirst().map(capitalize).joined()
        }
        return escapedIdentifier(base, fallback: fallback)
    }

    static func enumCaseNameFromType(_ raw: String, fallback: String) -> String {
        let value = raw.typeNameLeaf
        guard !value.isEmpty else {
            return enumCaseName(fallback, fallback: fallback)
        }

        guard let lowerCamel = value.lowerCamelCasedTypeName else {
            return enumCaseName(value, fallback: fallback)
        }

        return escapedIdentifier(lowerCamel, fallback: fallback)
    }

    static func qualifiedComponent(_ raw: String, fallback: String) -> String {
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.isEmpty {
            return fallback
        }
        if isSwiftIdentifier(candidate), !swiftKeywords.contains(candidate) {
            return candidate
        }
        if isSwiftIdentifier(candidate) {
            return "`\(candidate)`"
        }
        return typeName(candidate, fallback: fallback)
    }

    private static func escapedIdentifier(_ raw: String, fallback: String) -> String {
        let candidate = raw.isEmpty ? fallback : raw
        if isSwiftIdentifier(candidate), !swiftKeywords.contains(candidate) {
            return candidate
        }
        if candidate == "_" {
            return fallback
        }
        if isSwiftIdentifier(candidate) {
            return "`\(candidate)`"
        }
        let normalized = "field\(capitalize(candidate))"
        if isSwiftIdentifier(normalized), !swiftKeywords.contains(normalized) {
            return normalized
        }
        return fallback
    }

    private static func split(_ raw: String) -> [String] {
        raw
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func capitalize(_ value: String) -> String {
        guard let first = value.first else { return value }
        return first.uppercased() + value.dropFirst()
    }

    private static func lowercasedFirst(_ value: String) -> String {
        guard let first = value.first else { return value }
        return first.lowercased() + value.dropFirst()
    }

    private static func isSwiftIdentifier(_ value: String) -> Bool {
        guard let first = value.first else { return false }
        guard first == "_" || first.isLetter else { return false }
        return value.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }
}
