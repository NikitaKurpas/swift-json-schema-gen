import Foundation

extension SwiftEmitter {
    func renderTuple(_ value: TupleIR, nestedDeclarations: [String]) -> String {
        var lines: [String] = []
        lines.append(contentsOf: documentationLines(value.description, indent: ""))
        let declarationKind = value.isReferenceType ? "final class" : "struct"
        lines.append(
            "public \(declarationKind) \(value.name): Codable\(options.conformancesSuffix) {")
        for element in value.elements {
            lines.append(
                "    public let \(element.name): \(renderType(element.type, topLevel: true))")
        }
        if let additionalElementType = value.additionalElementType {
            lines.append(
                "    public let additionalItems: [\(renderType(additionalElementType, topLevel: false))]"
            )
        }

        lines.append("")
        var parameters = value.elements.map { "\($0.name): \(renderType($0.type, topLevel: true))" }
        if let additionalElementType = value.additionalElementType {
            parameters.append(
                "additionalItems: [\(renderType(additionalElementType, topLevel: false))] = []")
        }
        lines.append("    public init(\(parameters.joined(separator: ", "))) {")
        for element in value.elements {
            lines.append("        self.\(element.name) = \(element.name)")
        }
        if value.additionalElementType != nil {
            lines.append("        self.additionalItems = additionalItems")
        }
        lines.append("    }")

        lines.append("")
        lines.append("    public init(from decoder: Decoder) throws {")
        let decoderContainerBinding =
            value.elements.isEmpty && value.additionalElementType == nil ? "let" : "var"
        lines.append(
            "        \(decoderContainerBinding) container = try decoder.unkeyedContainer()")
        for element in value.elements {
            lines.append(
                "        self.\(element.name) = try container.decode(\(renderType(element.type, topLevel: false)).self)"
            )
        }
        if let additionalElementType = value.additionalElementType {
            lines.append(
                "        var additionalItems: [\(renderType(additionalElementType, topLevel: false))] = []"
            )
            lines.append("        while !container.isAtEnd {")
            if let maximumCount = value.maximumCount {
                lines.append(
                    "            guard additionalItems.count + \(value.elements.count) < \(maximumCount) else {"
                )
                lines.append(
                    "                throw DecodingError.dataCorruptedError(in: container, debugDescription: \"Tuple exceeds maxItems \(maximumCount)\")"
                )
                lines.append("            }")
            }
            lines.append(
                "            additionalItems.append(try container.decode(\(renderType(additionalElementType, topLevel: false)).self))"
            )
            lines.append("        }")
            lines.append("        self.additionalItems = additionalItems")
        } else {
            lines.append("        guard container.isAtEnd else {")
            lines.append(
                "            throw DecodingError.dataCorruptedError(in: container, debugDescription: \"Unexpected additional tuple item\")"
            )
            lines.append("        }")
        }
        lines.append("    }")

        lines.append("")
        lines.append("    public func encode(to encoder: Encoder) throws {")
        if value.elements.isEmpty && value.additionalElementType == nil {
            lines.append("        _ = encoder.unkeyedContainer()")
        } else {
            lines.append("        var container = encoder.unkeyedContainer()")
        }
        for element in value.elements {
            lines.append("        try container.encode(\(element.name))")
        }
        if value.additionalElementType != nil {
            lines.append("        for item in additionalItems { try container.encode(item) }")
        }
        lines.append("    }")

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
}
