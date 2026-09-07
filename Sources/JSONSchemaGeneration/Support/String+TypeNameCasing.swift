import Foundation

extension String {
    var typeNameLeaf: String {
        let cleaned = replacingOccurrences(of: "`", with: "")
        return cleaned.split(separator: ".").last.map(String.init) ?? cleaned
    }

    var lowerCamelCasedTypeName: String? {
        let words = splitTypeNameWords()
        guard !words.isEmpty else { return nil }
        let first = words[0].lowercased()
        let tail = words.dropFirst().map(Self.capitalizedLowercased).joined()
        return first + tail
    }

    private func splitTypeNameWords() -> [String] {
        guard !isEmpty else { return [] }
        var words: [String] = []
        var current = ""
        let chars = Array(self)

        func flush() {
            guard !current.isEmpty else { return }
            words.append(current)
            current = ""
        }

        for index in chars.indices {
            let char = chars[index]
            if !(char.isLetter || char.isNumber) {
                flush()
                continue
            }

            if current.isEmpty {
                current.append(char)
                continue
            }

            let previous = chars[index - 1]
            let next = index + 1 < chars.count ? chars[index + 1] : nil
            let boundary: Bool

            if previous.isLowercase && char.isUppercase {
                boundary = true
            } else if previous.isUppercase && char.isUppercase && (next?.isLowercase == true) {
                boundary = true
            } else if previous.isNumber != char.isNumber {
                boundary = true
            } else {
                boundary = false
            }

            if boundary {
                flush()
            }
            current.append(char)
        }

        flush()
        return words
    }

    private static func capitalizedLowercased(_ value: String) -> String {
        let lowered = value.lowercased()
        guard let first = lowered.first else { return lowered }
        return first.uppercased() + lowered.dropFirst()
    }
}
