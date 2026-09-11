import Foundation

extension JSONValue {
    /// Resolves an RFC 6901 JSON Pointer after URI-fragment percent decoding.
    func resolvingJSONPointer(_ pointer: String, reference: String? = nil) throws -> JSONValue {
        if pointer.isEmpty {
            return self
        }
        guard pointer.first == "/" else {
            throw GenerationError.schema(
                "invalid JSON Pointer fragment '\(displayReference(reference, pointer: pointer))': expected an empty fragment or one beginning with '/'"
            )
        }

        var current = self
        for token in try decodedJSONPointerTokens(pointer, reference: reference ?? "#\(pointer)") {

            switch current.type {
            case .dictionary:
                guard let next = current.dictionaryValue[token] else {
                    throw unresolvedPointer(reference, pointer: pointer, token: token)
                }
                current = next
            case .array:
                guard isCanonicalArrayIndex(token), let index = Int(token),
                    current.arrayValue.indices.contains(index)
                else {
                    throw unresolvedPointer(reference, pointer: pointer, token: token)
                }
                current = current.arrayValue[index]
            default:
                throw unresolvedPointer(reference, pointer: pointer, token: token)
            }
        }
        return current
    }
}

func decodedJSONPointerTokens(_ pointer: String, reference: String) throws -> [String] {
    guard pointer.first == "/" else { return [] }
    return try pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map {
        try decodeJSONPointerToken(String($0), reference: reference)
    }
}

private func decodeJSONPointerToken(_ token: String, reference: String) throws -> String {
    var result = ""
    var index = token.startIndex
    while index < token.endIndex {
        if token[index] != "~" {
            result.append(token[index])
            index = token.index(after: index)
            continue
        }

        let escapedIndex = token.index(after: index)
        guard escapedIndex < token.endIndex else {
            throw GenerationError.schema(
                "invalid JSON Pointer escape in reference '\(reference)': '~' must be followed by '0' or '1'"
            )
        }
        switch token[escapedIndex] {
        case "0": result.append("~")
        case "1": result.append("/")
        default:
            throw GenerationError.schema(
                "invalid JSON Pointer escape in reference '\(reference)': '~\(token[escapedIndex])' is not valid"
            )
        }
        index = token.index(after: escapedIndex)
    }
    return result
}

private func isCanonicalArrayIndex(_ token: String) -> Bool {
    guard !token.isEmpty else { return false }
    if token == "0" { return true }
    guard token.first?.isNumber == true, token.first != "0" else { return false }
    return token.allSatisfy(\.isNumber)
}

private func unresolvedPointer(_ reference: String?, pointer: String, token: String)
    -> GenerationError
{
    GenerationError.schema(
        "unresolved JSON Pointer '\(displayReference(reference, pointer: pointer))': token '\(token)' does not exist"
    )
}

private func displayReference(_ reference: String?, pointer: String) -> String {
    reference ?? "#\(pointer)"
}
