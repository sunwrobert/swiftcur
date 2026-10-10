import Foundation

/// Ordered field list for args, options, env, globals, and object outputs.
public struct Shape: ExpressibleByDictionaryLiteral, Sendable {
    public var fields: [(name: String, schema: Schema)]

    public init(_ fields: [(name: String, schema: Schema)]) { self.fields = fields }

    public init(dictionaryLiteral elements: (String, Schema)...) {
        fields = elements.map { (name: $0.0, schema: $0.1) }
    }

    public var names: [String] { fields.map(\.name) }
    public var isEmpty: Bool { fields.isEmpty }

    public subscript(name: String) -> Schema? {
        fields.first { $0.name == name }?.schema
    }
}

/// A field type with validation and JSON Schema output. The Swift counterpart of incur's Zod schemas.
///
/// Modifiers mirror Zod, including where annotations land in the generated JSON Schema:
/// `describe` before `optional`/`default` describes the inner type, after it describes the wrapper.
public struct Schema: Sendable {
    public indirect enum Kind: Sendable {
        case string, number, integer, boolean, any
        case array(Schema)
        case object(Shape)
        case choice([String])
        case literals([String])
    }

    public internal(set) var kind: Kind
    public internal(set) var isOptional = false
    public internal(set) var defaultValue: JSON?
    public internal(set) var description: String?
    public internal(set) var isCount = false
    public internal(set) var isDeprecated = false
    var coerces = false
    var minimum: Double?
    var maximum: Double?
    private var isWrapped = false
    private var outerKeys: [(String, JSON)] = []
    private var innerKeys: [(String, JSON)] = []

    init(_ kind: Kind) { self.kind = kind }

    // MARK: Constructors

    public static var string: Schema { Schema(.string) }
    public static var number: Schema { Schema(.number) }
    public static var int: Schema { Schema(.integer) }
    public static var boolean: Schema { Schema(.boolean) }
    public static var any: Schema { Schema(.any) }
    public static func array(_ items: Schema) -> Schema { Schema(.array(items)) }
    public static func object(_ shape: Shape) -> Schema { Schema(.object(shape)) }
    /// One of a fixed set of strings (Zod `z.enum`).
    public static func choice(_ values: String...) -> Schema { Schema(.choice(values)) }
    public static func choice(_ values: [String]) -> Schema { Schema(.choice(values)) }
    /// A union of string literals (Zod `z.union([z.literal(…)])`).
    public static func literals(_ values: String...) -> Schema { Schema(.literals(values)) }
    /// A counter flag: `-vvv` gives 3. Defaults to 0.
    public static var count: Schema {
        var schema = Schema.number.default(0)
        schema.isCount = true
        schema.annotate("count", true)
        return schema
    }

    // MARK: Modifiers

    public func optional() -> Schema {
        var copy = self
        copy.isOptional = true
        copy.isWrapped = true
        return copy
    }

    public func `default`(_ value: JSON) -> Schema {
        var copy = self
        copy.defaultValue = value
        copy.isWrapped = true
        copy.outerKeys.append(("default", value))
        return copy
    }

    public func describe(_ text: String) -> Schema {
        var copy = self
        copy.description = text
        copy.annotate("description", .string(text))
        return copy
    }

    public func deprecated() -> Schema {
        var copy = self
        copy.isDeprecated = true
        copy.annotate("deprecated", true)
        return copy
    }

    /// Minimum value, string length, or item count.
    public func min(_ value: Double) -> Schema {
        var copy = self
        copy.minimum = value
        return copy
    }

    /// Maximum value, string length, or item count.
    public func max(_ value: Double) -> Schema {
        var copy = self
        copy.maximum = value
        return copy
    }

    /// Convert strings to this type before validating (Zod `z.coerce`).
    public func coerce() -> Schema {
        var copy = self
        copy.coerces = true
        return copy
    }

    private mutating func annotate(_ key: String, _ value: JSON) {
        if isWrapped { outerKeys.append((key, value)) } else { innerKeys.append((key, value)) }
    }

    // MARK: Introspection

    var isBoolean: Bool {
        if case .boolean = kind { return true }
        return false
    }

    var isArray: Bool {
        if case .array = kind { return true }
        return false
    }

    /// Whether the field must be present after defaults are applied.
    var isRequired: Bool { !isOptional && defaultValue == nil }

    /// Short type name used in help (`string`, `number`, `a|b`, …).
    var typeName: String {
        if isCount { return "count" }
        switch kind {
        case .string: return "string"
        case .number, .integer: return "number"
        case .boolean: return "boolean"
        case .array: return "array"
        case .choice(let values), .literals(let values): return values.joined(separator: "|")
        case .object, .any: return "value"
        }
    }

    /// Values offered by shell completion.
    var possibleValues: [String]? {
        switch kind {
        case .choice(let values), .literals(let values): return values
        default: return nil
        }
    }

    // MARK: JSON Schema

    public var jsonSchema: JSON { .object(jsonSchemaObject) }

    var jsonSchemaObject: JSONObject {
        var out = JSONObject()
        for (key, value) in outerKeys { out[key] = value }
        for (key, value) in baseKeys() { out[key] = value }
        for (key, value) in innerKeys { out[key] = value }
        return out
    }

    private func baseKeys() -> [(String, JSON)] {
        switch kind {
        case .string:
            var keys: [(String, JSON)] = [("type", "string")]
            if let minimum { keys.append(("minLength", .number(minimum))) }
            if let maximum { keys.append(("maxLength", .number(maximum))) }
            return keys
        case .number:
            var keys: [(String, JSON)] = [("type", "number")]
            if let minimum { keys.append(("minimum", .number(minimum))) }
            if let maximum { keys.append(("maximum", .number(maximum))) }
            return keys
        case .integer:
            return [
                ("type", "integer"),
                ("minimum", .number(minimum ?? -9_007_199_254_740_991)),
                ("maximum", .number(maximum ?? 9_007_199_254_740_991)),
            ]
        case .boolean: return [("type", "boolean")]
        case .any: return []
        case .array(let items):
            var keys: [(String, JSON)] = []
            if let minimum { keys.append(("minItems", .number(minimum))) }
            if let maximum { keys.append(("maxItems", .number(maximum))) }
            return keys + [("type", "array"), ("items", items.jsonSchema)]
        case .object(let shape): return Schema.objectSchema(shape).map { ($0.key, $0.value) }
        case .choice(let values): return [("type", "string"), ("enum", .array(values.map(JSON.string)))]
        case .literals(let values):
            return [("anyOf", .array(values.map { .object(["type": "string", "const": .string($0)]) }))]
        }
    }

    /// JSON Schema for an object with these fields.
    static func objectSchema(_ shape: Shape) -> JSONObject {
        var properties = JSONObject()
        for field in shape.fields { properties[field.name] = field.schema.jsonSchema }
        var out: JSONObject = ["type": "object", "properties": .object(properties)]
        let required = shape.fields.filter { !$0.schema.isOptional }.map { JSON.string($0.name) }
        if !required.isEmpty { out["required"] = .array(required) }
        out["additionalProperties"] = false
        return out
    }
}
