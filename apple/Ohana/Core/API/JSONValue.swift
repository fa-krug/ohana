import Foundation

/// Any JSON: for payloads the app passes through without a model of its own (the assistant's
/// undo steps, settings blobs, tool arguments).
nonisolated enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let boolean = try? container.decode(Bool.self) { self = .bool(boolean) }
        else if let numericValue = try? container.decode(Double.self) { self = .number(numericValue) }
        else if let textValue = try? container.decode(String.self) { self = .string(textValue) }
        else if let items = try? container.decode([JSONValue].self) { self = .array(items) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(boolean): try container.encode(boolean)
        case let .number(numericValue): try container.encode(numericValue)
        case let .string(textValue): try container.encode(textValue)
        case let .array(items): try container.encode(items)
        case let .object(entries): try container.encode(entries)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case let .object(entries) = self { entries[key] } else { nil }
    }

    var stringValue: String? { if case let .string(textValue) = self { textValue } else { nil } }
    var doubleValue: Double? { if case let .number(numericValue) = self { numericValue } else { nil } }
    var boolValue: Bool? { if case let .bool(boolean) = self { boolean } else { nil } }
    var arrayValue: [JSONValue]? { if case let .array(items) = self { items } else { nil } }
    var objectValue: [String: JSONValue]? { if case let .object(entries) = self { entries } else { nil } }
}

/// An empty request or response body.
nonisolated struct Empty: Codable, Sendable {}
