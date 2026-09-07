import Foundation

indirect enum SwiftType: Equatable, Hashable {
    case string
    case int
    case double
    case bool
    case null
    case named(String)
    case array(SwiftType)
    case dictionary(SwiftType)
    case existential
    case optional(SwiftType)

    var rendered: String {
        switch self {
        case .string:
            return "String"
        case .int:
            return "Int"
        case .double:
            return "Double"
        case .bool:
            return "Bool"
        case .null:
            return "NullValue"
        case .named(let name):
            return name
        case .array(let item):
            return "[\(item.rendered)]"
        case .dictionary(let value):
            return "[String: \(value.rendered)]"
        case .existential:
            return "__EXISTENTIAL__"
        case .optional(let wrapped):
            return "\(wrapped.rendered)?"
        }
    }

    var isOptional: Bool {
        if case .optional = self {
            return true
        }
        return false
    }

    func wrappedOptional() -> SwiftType {
        if isOptional {
            return self
        }
        return .optional(self)
    }
}

struct PropertyIR: Hashable {
    let schemaKey: String
    let swiftName: String
    var type: SwiftType
    var requiredByAllInputs: Bool
    var allowsNull: Bool = false

    var needsCodingKey: Bool {
        schemaKey != swiftName.replacingOccurrences(of: "`", with: "")
    }

    var isExistential: Bool {
        containsExistential(type)
    }

    private func containsExistential(_ value: SwiftType) -> Bool {
        switch value {
        case .existential:
            return true
        case .null:
            return false
        case .array(let inner):
            return containsExistential(inner)
        case .dictionary(let inner):
            return containsExistential(inner)
        case .optional(let inner):
            return containsExistential(inner)
        default:
            return false
        }
    }
}

struct StructIR: Hashable {
    let name: String
    var description: String?
    var properties: [PropertyIR]
    var isReferenceType: Bool = false
    var additionalProperties: AdditionalPropertiesIR = .ignored
}

enum AdditionalPropertiesIR: Hashable {
    case ignored
    case captured(SwiftType)
    case forbidden
}

enum UnionKind: Hashable {
    case oneOf
    case anyOf
}

enum EnumCaseLiteralIR: Hashable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case null
}

struct EnumCaseIR: Hashable {
    let name: String
    let description: String?
    let associatedType: SwiftType?
    let literal: EnumCaseLiteralIR?
}

struct EnumIR: Hashable {
    let name: String
    var description: String?
    var discriminatorKey: String?
    var cases: [EnumCaseIR]
    var unionKind: UnionKind = .anyOf
    var isIndirect: Bool = false
}

struct TupleElementIR: Hashable {
    let name: String
    let type: SwiftType
}

struct TupleIR: Hashable {
    let name: String
    var description: String?
    var elements: [TupleElementIR]
    var additionalElementType: SwiftType?
    var maximumCount: Int?
}

struct RawEnumCaseIR: Hashable {
    let name: String
    let rawValue: String
}

struct RawEnumIR: Hashable {
    let name: String
    var description: String?
    var cases: [RawEnumCaseIR]
}

enum TypeDeclIR: Hashable {
    case structDecl(StructIR)
    case enumDecl(EnumIR)
    case tupleDecl(TupleIR)
    case rawStringEnumDecl(RawEnumIR)
    case typeAliasDecl(DeclaredTypeAliasIR)

    var name: String {
        switch self {
        case .structDecl(let value):
            return value.name
        case .enumDecl(let value):
            return value.name
        case .tupleDecl(let value):
            return value.name
        case .rawStringEnumDecl(let value):
            return value.name
        case .typeAliasDecl(let value):
            return value.name
        }
    }
}

struct TypeAliasIR: Hashable {
    let name: String
    let target: String
}

struct DeclaredTypeAliasIR: Hashable {
    let name: String
    let target: SwiftType
}
