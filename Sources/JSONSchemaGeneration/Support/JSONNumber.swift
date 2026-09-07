import Foundation

enum JSONNumber: Equatable, Sendable {
    case signed(Int64)
    case unsigned(UInt64)
    case decimal(Decimal)
    case floating(Double)

    var decimal: Decimal? {
        switch self {
        case .signed(let value): return Decimal(value)
        case .unsigned(let value): return Decimal(value)
        case .decimal(let value): return value
        case .floating(let value): return Decimal(value)
        }
    }

    var int64: Int64? {
        switch self {
        case .signed(let value): return value
        case .unsigned(let value): return Int64(exactly: value)
        case .decimal(let value):
            let result = NSDecimalNumber(decimal: value).int64Value
            return Decimal(result) == value ? result : nil
        case .floating:
            return nil
        }
    }

    var double: Double {
        switch self {
        case .floating(let value): return value
        default: return NSDecimalNumber(decimal: decimal!).doubleValue
        }
    }

    var canonicalString: String {
        switch self {
        case .floating(let value): return value.description
        default: return decimal!.description
        }
    }

    static func == (lhs: JSONNumber, rhs: JSONNumber) -> Bool {
        switch (lhs, rhs) {
        case (.floating(let lhs), .floating(let rhs)):
            return lhs == rhs
        case (.floating(let lhs), _):
            return lhs == rhs.double
        case (_, .floating(let rhs)):
            return lhs.double == rhs
        default:
            return lhs.decimal == rhs.decimal
        }
    }
}
