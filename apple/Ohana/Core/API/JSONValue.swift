import Foundation

/// Any JSON: for payloads the app passes through without a model of its own (the assistant's
/// undo steps, settings blobs, tool arguments).
enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(b): try c.encode(b)
        case let .number(n): try c.encode(n)
        case let .string(s): try c.encode(s)
        case let .array(a): try c.encode(a)
        case let .object(o): try c.encode(o)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case let .object(o) = self { o[key] } else { nil }
    }

    var stringValue: String? { if case let .string(s) = self { s } else { nil } }
    var doubleValue: Double? { if case let .number(n) = self { n } else { nil } }
    var boolValue: Bool? { if case let .bool(b) = self { b } else { nil } }
    var arrayValue: [JSONValue]? { if case let .array(a) = self { a } else { nil } }
    var objectValue: [String: JSONValue]? { if case let .object(o) = self { o } else { nil } }
}

/// An empty request or response body.
struct Empty: Codable, Sendable {}
