import Foundation

/// The JSON values needed while reading and resolving a schema.
///
/// A missing object member is represented by `missing`, while an explicitly
/// encoded `null` is represented by `null`. Keeping those states separate is
/// important for JSON Schema keywords such as `const`, `enum`, and `required`.
enum JSONValue: Decodable, Equatable, Sendable {
    case missing
    case null
    case bool(Bool)
    case number(JSONNumber)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Int64.self) {
            self = .number(.signed(value))
            return
        }
        if let value = try? container.decode(UInt64.self) {
            self = .number(.unsigned(value))
            return
        }
        if let value = try? container.decode(Decimal.self) {
            self = .number(.decimal(value))
            return
        }
        if let value = try? container.decode(Double.self), value.isFinite {
            self = .number(.floating(value))
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
            return
        }
        self = .object(try container.decode([String: JSONValue].self))
    }

    var type: JSONValueType {
        switch self {
        case .missing: return .missing
        case .null: return .null
        case .bool: return .bool
        case .number: return .number
        case .string: return .string
        case .array: return .array
        case .object: return .dictionary
        }
    }

    func exists() -> Bool { self != .missing }

    subscript(key: String) -> JSONValue {
        get {
            guard case .object(let values) = self else { return .missing }
            return values[key] ?? .missing
        }
        set {
            guard case .object(var values) = self else {
                self = .object([key: newValue])
                return
            }
            values[key] = newValue
            self = .object(values)
        }
    }

    var dictionary: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var dictionaryValue: [String: JSONValue] { dictionary ?? [:] }

    var array: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue] { array ?? [] }

    var string: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var bool: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var int64: Int64? {
        guard case .number(let value) = self else { return nil }
        return value.int64
    }

    var int: Int? {
        guard let value = int64, let result = Int(exactly: value) else { return nil }
        return result
    }

    var double: Double? {
        guard case .number(let value) = self else { return nil }
        return value.double
    }

    /// A numeric value, exposed for shape checks without exposing storage.
    var number: Decimal? {
        guard case .number(let value) = self else { return nil }
        return value.decimal
    }

    /// A stable, sorted representation used for duplicate JSON-value checks.
    /// Numeric spellings that represent the same value are normalized.
    var canonicalJSONString: String? {
        guard self != .missing else { return nil }
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value): return value.canonicalString
        case .string(let value): return Self.encodedJSONString(value)
        case .array(let values):
            return "[" + values.compactMap(\.canonicalJSONString).joined(separator: ",") + "]"
        case .object(let values):
            return "{"
                + values.keys.sorted().compactMap { key in
                    guard let value = values[key], let canonical = value.canonicalJSONString else {
                        return nil
                    }
                    guard let encodedKey = Self.encodedJSONString(key) else { return nil }
                    return "\(encodedKey):\(canonical)"
                }.joined(separator: ",") + "}"
        case .missing: return nil
        }
    }

    private static func encodedJSONString(_ value: String) -> String? {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.fragmentsAllowed])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.missing, .missing), (.null, .null): return true
        case (.bool(let lhs), .bool(let rhs)): return lhs == rhs
        case (.number(let lhs), .number(let rhs)): return lhs == rhs
        case (.string(let lhs), .string(let rhs)): return lhs == rhs
        case (.array(let lhs), .array(let rhs)): return lhs == rhs
        case (.object(let lhs), .object(let rhs)):
            return lhs == rhs
        default: return false
        }
    }
}
