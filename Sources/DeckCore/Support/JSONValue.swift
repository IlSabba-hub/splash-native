import Foundation

public enum JSONValue: Codable, Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var int: Int64? {
        switch self {
        case .int(let value): value
        case .double(let value) where value.rounded() == value: Int64(exactly: value)
        default: nil
        }
    }

    public var string: String? { if case .string(let value) = self { value } else { nil } }

    public var strings: [String]? {
        guard case .array(let items) = self else { return nil }
        let strings = items.compactMap(\.string)
        return strings.count == items.count ? strings : nil
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let fields) = self { fields[key] } else { nil }
    }

    public var text: String? {
        switch self {
        case .null: nil
        case .bool(let value): value ? "true" : "false"
        case .int(let value): String(value)
        case .double(let value): String(value)
        case .string(let value): value
        case .array, .object: nil
        }
    }
}
