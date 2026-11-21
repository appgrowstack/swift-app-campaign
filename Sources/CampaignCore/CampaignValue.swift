import Foundation

/// A value in an event's properties, a fact about the person, or an action argument.
public enum CampaignValue: Sendable, Hashable, Codable, CustomStringConvertible {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else { self = .string(try container.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }

    /// The value as text, for analytics pipelines that send every parameter as a string.
    public var description: String {
        switch self {
        case .string(let value): value
        case .int(let value): String(value)
        case .double(let value): String(value)
        case .bool(let value): value ? "true" : "false"
        }
    }

    var number: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }

    var kind: Kind {
        switch self {
        case .string: .string
        case .int, .double: .number
        case .bool: .bool
        }
    }

    enum Kind { case string, number, bool }

    /// `nil` when the two cannot be compared (a type mismatch).
    func equals(_ other: CampaignValue) -> Bool? {
        guard kind == other.kind else { return nil }
        if let lhs = number, let rhs = other.number { return lhs == rhs }
        return self == other
    }
}

extension CampaignValue {
    /// A value from an analytics client that keeps `[String: Any]`: `Bool`, integers, `Double`,
    /// `Float`, `String`, or an `NSNumber` read by its real type. `nil` for anything else (leave it out).
    public init?(any value: Any) {
        if let number = value as? NSNumber, !(value is String) {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
                return
            }
            switch String(cString: number.objCType) {
            case "f", "d": self = .double(number.doubleValue)
            default: self = .int(number.intValue)
            }
            return
        }
        switch value {
        case let value as CampaignValue: self = value
        case let value as Bool: self = .bool(value)
        case let value as Int: self = .int(value)
        case let value as Int64: self = .int(Int(value))
        case let value as Int32: self = .int(Int(value))
        case let value as Double: self = .double(value)
        case let value as Float: self = .double(Double(value))
        case let value as String: self = .string(value)
        default: return nil
        }
    }
}

extension CampaignValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}
