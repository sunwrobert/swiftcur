import Foundation

/// A JSON value. Objects keep insertion order, so output matches what you built.
public enum JSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object(JSONObject)

    /// Converts an `Encodable` value. Struct keys keep their declaration order.
    public init<T: Encodable>(encoding value: T) throws {
        self = try JSONValueEncoder().encode(value)
    }

    /// Decodes this value into a `Decodable` type.
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(type, from: Data(JSONWriter.stringify(self).utf8))
    }

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        guard case let .number(value) = self, value.rounded() == value, abs(value) < 9e18 else { return nil }
        return Int(value)
    }

    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    public var arrayValue: [JSON]? {
        if case let .array(value) = self { return value }
        return nil
    }

    public var objectValue: JSONObject? {
        if case let .object(value) = self { return value }
        return nil
    }

    /// Whether this is a string, number, boolean, or null.
    public var isScalar: Bool {
        switch self {
        case .array, .object: return false
        case .null, .bool, .number, .string: return true
        }
    }

    public subscript(key: String) -> JSON? {
        objectValue?[key]
    }

    public subscript(index: Int) -> JSON? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }

    /// Text the way JavaScript's `String(value)` renders it.
    var plainText: String {
        switch self {
        case .null: return "null"
        case let .bool(value): return value ? "true" : "false"
        case let .number(value): return JSONWriter.number(value)
        case let .string(value): return value
        case let .array(items): return items.map { $0.isNull ? "" : $0.plainText }.joined(separator: ",")
        case .object: return "[object Object]"
        }
    }

    var isNull: Bool { self == .null }

    /// JavaScript `typeof`-style name used in validation messages.
    var typeName: String {
        switch self {
        case .null: return "null"
        case .bool: return "boolean"
        case let .number(value):
            if value.isNaN { return "NaN" }
            if value.isInfinite { return value > 0 ? "Infinity" : "-Infinity" }
            return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSON: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension JSON: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension JSON: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSON: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSON: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
}

extension JSON: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSON)...) { self = .object(JSONObject(elements)) }
}

extension JSON: CustomStringConvertible {
    public var description: String { JSONWriter.stringify(self) }
}

extension JSON: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSON].self) {
            self = .array(value)
        } else {
            let keyed = try decoder.container(keyedBy: AnyKey.self)
            var object = JSONObject()
            for key in keyed.allKeys { object[key.stringValue] = try keyed.decode(JSON.self, forKey: key) }
            self = .object(object)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case let .bool(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .number(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .string(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .array(items):
            var container = encoder.unkeyedContainer()
            for item in items { try container.encode(item) }
        case let .object(object):
            var container = encoder.container(keyedBy: AnyKey.self)
            for (key, value) in object { try container.encode(value, forKey: AnyKey(key)) }
        }
    }
}

struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { stringValue = String(intValue) }
}
