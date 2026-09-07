import Foundation

extension String {
    var schemaRefComponents: (path: String, fragment: String) {
        let parts = split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 1 {
            return (String(parts[0]), "")
        }
        return (String(parts[0]), String(parts[1]))
    }

    var decodedJSONPointerTokens: [String] {
        guard !isEmpty, first == "/" else { return [] }
        return split(separator: "/", omittingEmptySubsequences: true).map {
            String($0)
                .replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
        }
    }

    var decodedSchemaRefTokens: [String] {
        schemaRefComponents.fragment.decodedJSONPointerTokens
    }

    var lastDecodedSchemaRefToken: String? {
        decodedSchemaRefTokens.last
    }

    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var isTypeLikeIdentifier: Bool {
        guard let first, first.isUppercase else { return false }
        return !contains(where: { !$0.isLetter && !$0.isNumber && $0 != "_" })
    }
}

extension Optional where Wrapped == String {
    var trimmedNonEmpty: String? {
        self?.trimmedNonEmpty
    }
}
