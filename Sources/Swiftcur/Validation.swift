import Foundation

/// One validation problem, shaped like a Zod v4 issue so error output matches incur.
struct Issue {
    var code: String
    var path: [JSON]
    var message: String
    var expected = ""
    var received = ""
    /// Extra fields in Zod's key order, used for the `Details:` JSON.
    var fields: [(String, JSON)]

    var json: JSON {
        var object = JSONObject()
        for (key, value) in fields { object[key] = value }
        object["path"] = .array(path)
        object["message"] = .string(message)
        return .object(object)
    }

    var pathText: String { path.map(\.plainText).joined(separator: ".") }
}

extension Schema {
    /// Validates an object against a shape: applies defaults, drops unknown keys, collects issues.
    static func parse(_ shape: Shape, _ data: JSONObject) throws -> JSONObject {
        var issues: [Issue] = []
        let result = parseObject(shape, data, path: [], issues: &issues)
        guard issues.isEmpty else { throw ValidationError(issues: issues, raw: .object(data)) }
        return result
    }

    private static func parseObject(_ shape: Shape, _ data: JSONObject, path: [JSON], issues: inout [Issue]) -> JSONObject {
        var out = JSONObject()
        for field in shape.fields {
            if let value = field.schema.parse(data[field.name], path: path + [.string(field.name)], issues: &issues) {
                out[field.name] = value
            }
        }
        return out
    }

    /// Returns the parsed value, or `nil` when an optional field is absent.
    func parse(_ input: JSON?, path: [JSON], issues: inout [Issue]) -> JSON? {
        guard var value = input else {
            if let defaultValue { return defaultValue }
            if isOptional { return nil }
            switch kind {
            case .choice(let values), .literals(let values): issues.append(choiceIssue(values, path: path))
            default: issues.append(typeIssue(expected: expectedName, received: nil, path: path))
            }
            return nil
        }
        if coerces { value = coerced(value) }

        switch kind {
        case .any:
            return value
        case .string:
            guard case .string(let text) = value else { return fail(value, path, &issues) }
            checkBounds(Double(text.count), origin: "string", path: path, issues: &issues)
            return value
        case .number, .integer:
            guard case .number(let number) = value, number.isFinite else { return fail(value, path, &issues) }
            if case .integer = kind, number.rounded() != number {
                issues.append(Issue(code: "invalid_type", path: path, message: "Invalid input: expected int, received number",
                                    expected: "int", fields: [("expected", "int"), ("format", "safeint"), ("code", "invalid_type")]))
                return value
            }
            checkBounds(number, origin: "number", path: path, issues: &issues)
            return value
        case .boolean:
            guard case .bool = value else { return fail(value, path, &issues) }
            return value
        case .choice(let values), .literals(let values):
            guard case .string(let text) = value, values.contains(text) else {
                issues.append(choiceIssue(values, path: path))
                return value
            }
            return value
        case .array(let itemSchema):
            guard case .array(let items) = value else { return fail(value, path, &issues) }
            let parsed = items.enumerated().map { index, item in
                itemSchema.parse(item, path: path + [.number(Double(index))], issues: &issues) ?? .null
            }
            checkBounds(Double(items.count), origin: "array", path: path, issues: &issues)
            return .array(parsed)
        case .object(let shape):
            guard case .object(let object) = value else { return fail(value, path, &issues) }
            return .object(Schema.parseObject(shape, object, path: path, issues: &issues))
        }
    }

    private var expectedName: String {
        switch kind {
        case .string, .choice, .literals: return "string"
        case .number, .integer: return "number"
        case .boolean: return "boolean"
        case .array: return "array"
        case .object: return "object"
        case .any: return "unknown"
        }
    }

    private func fail(_ value: JSON, _ path: [JSON], _ issues: inout [Issue]) -> JSON {
        issues.append(typeIssue(expected: expectedName, received: value, path: path))
        return value
    }

    private func typeIssue(expected: String, received value: JSON?, path: [JSON]) -> Issue {
        let receivedName = value?.typeName ?? "undefined"
        var fields: [(String, JSON)] = [("expected", .string(expected)), ("code", "invalid_type")]
        var received = ""
        if receivedName == "NaN" || receivedName.hasSuffix("Infinity") {
            fields.append(("received", .string(receivedName)))
            received = receivedName
        }
        return Issue(code: "invalid_type", path: path, message: "Invalid input: expected \(expected), received \(receivedName)",
                     expected: expected, received: received, fields: fields)
    }

    private func choiceIssue(_ values: [String], path: [JSON]) -> Issue {
        let quoted = values.map { "\"\($0)\"" }
        let message = values.count == 1
            ? "Invalid input: expected \(quoted[0])"
            : "Invalid option: expected one of \(quoted.joined(separator: "|"))"
        return Issue(code: "invalid_value", path: path, message: message,
                     fields: [("code", "invalid_value"), ("values", .array(values.map(JSON.string)))])
    }

    private func checkBounds(_ measure: Double, origin: String, path: [JSON], issues: inout [Issue]) {
        let unit = origin == "string" ? " characters" : origin == "array" ? " items" : ""
        let verb = origin == "number" ? "be" : "have"
        if let minimum, measure < minimum {
            issues.append(Issue(code: "too_small", path: path,
                                message: "Too small: expected \(origin) to \(verb) >=\(JSONWriter.number(minimum))\(unit)",
                                fields: [("origin", .string(origin)), ("code", "too_small"), ("minimum", .number(minimum)), ("inclusive", true)]))
        }
        if let maximum, measure > maximum {
            issues.append(Issue(code: "too_big", path: path,
                                message: "Too big: expected \(origin) to \(verb) <=\(JSONWriter.number(maximum))\(unit)",
                                fields: [("origin", .string(origin)), ("code", "too_big"), ("maximum", .number(maximum)), ("inclusive", true)]))
        }
    }

    private func coerced(_ value: JSON) -> JSON {
        switch kind {
        case .number, .integer:
            if case .string(let text) = value { return .number(jsNumber(text)) }
            if case .bool(let flag) = value { return .number(flag ? 1 : 0) }
            return value
        case .boolean:
            switch value {
            case .string(let text): return .bool(!text.isEmpty)
            case .number(let number): return .bool(number != 0 && !number.isNaN)
            case .null: return .bool(false)
            default: return value
            }
        case .string:
            return value.stringValue == nil && value.isScalar ? .string(value.plainText) : value
        default:
            return value
        }
    }
}

/// JavaScript `Number(text)`.
func jsNumber(_ text: String) -> Double {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return 0 }
    switch trimmed {
    case "Infinity", "+Infinity": return .infinity
    case "-Infinity": return -.infinity
    default: break
    }
    let lower = trimmed.lowercased()
    for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where lower.hasPrefix(prefix) {
        return Int(lower.dropFirst(2), radix: radix).map(Double.init) ?? .nan
    }
    guard trimmed.range(of: #"^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$"#, options: .regularExpression) != nil else { return .nan }
    return Double(trimmed) ?? .nan
}
