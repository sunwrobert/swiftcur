import Foundation

/// TOON encoder (Token-Oriented Object Notation, https://github.com/toon-format/spec).
/// Comma delimiter, 2-space indent, no key folding: the same settings incur uses.
enum Toon {
    static func encode(_ value: JSON) -> String {
        var lines: [String] = []
        switch value {
        case .array(let items): arrayLines(key: nil, items, depth: 0, into: &lines)
        case .object(let object): objectLines(object, depth: 0, into: &lines)
        default:
            let text = primitive(value)
            if !text.isEmpty { lines.append(text) }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Objects

    private static func objectLines(_ object: JSONObject, depth: Int, into lines: inout [String]) {
        for (key, value) in object { pairLines(key: key, value, depth: depth, into: &lines) }
    }

    private static func pairLines(key: String, _ value: JSON, depth: Int, into lines: inout [String]) {
        switch value {
        case .array(let items): arrayLines(key: key, items, depth: depth, into: &lines)
        case .object(let object):
            lines.append(line(depth, "\(encodeKey(key)):"))
            if !object.isEmpty { objectLines(object, depth: depth + 1, into: &lines) }
        default: lines.append(line(depth, "\(encodeKey(key)): \(primitive(value))"))
        }
    }

    // MARK: Arrays

    private static func arrayLines(key: String?, _ items: [JSON], depth: Int, into lines: inout [String]) {
        if items.isEmpty {
            lines.append(line(depth, key.map { "\(encodeKey($0)): []" } ?? "[]"))
            return
        }
        if items.allSatisfy(\.isScalar) {
            lines.append(line(depth, inline(items, key: key)))
            return
        }
        if items.allSatisfy({ $0.arrayValue?.allSatisfy(\.isScalar) == true }) {
            lines.append(line(depth, header(items.count, key: key)))
            for item in items { lines.append(listItem(depth + 1, inline(item.arrayValue!, key: nil))) }
            return
        }
        if items.allSatisfy({ $0.objectValue != nil }), let fields = tabularFields(items) {
            lines.append(line(depth, header(items.count, key: key, fields: fields)))
            rows(items, fields: fields, depth: depth + 1, into: &lines)
            return
        }
        lines.append(line(depth, header(items.count, key: key)))
        for item in items { listItemLines(item, depth: depth + 1, into: &lines) }
    }

    /// Field names for tabular form: every row has the same keys and only primitive values.
    private static func tabularFields(_ rows: [JSON]) -> [String]? {
        guard let first = rows.first?.objectValue, !first.isEmpty else { return nil }
        let fields = first.keys
        for row in rows {
            guard let object = row.objectValue, object.count == fields.count else { return nil }
            for field in fields {
                guard let value = object[field], value.isScalar else { return nil }
            }
        }
        return fields
    }

    private static func rows(_ items: [JSON], fields: [String], depth: Int, into lines: inout [String]) {
        for item in items {
            let cells = fields.map { primitive(item.objectValue![$0]!) }
            lines.append(line(depth, cells.joined(separator: ",")))
        }
    }

    private static func listItemLines(_ value: JSON, depth: Int, into lines: inout [String]) {
        switch value {
        case .array(let items):
            if items.allSatisfy(\.isScalar) {
                lines.append(listItem(depth, inline(items, key: nil)))
            } else {
                lines.append(listItem(depth, header(items.count, key: nil)))
                for item in items { listItemLines(item, depth: depth + 1, into: &lines) }
            }
        case .object(let object): objectListItemLines(object, depth: depth, into: &lines)
        default: lines.append(listItem(depth, primitive(value)))
        }
    }

    /// An object as a list item: the first field sits on the hyphen line.
    private static func objectListItemLines(_ object: JSONObject, depth: Int, into lines: inout [String]) {
        guard let firstKey = object.keys.first, let firstValue = object[firstKey] else {
            lines.append(line(depth, "-"))
            return
        }
        var rest = object
        rest.removeValue(forKey: firstKey)
        let key = encodeKey(firstKey)

        switch firstValue {
        case .array(let items):
            if items.isEmpty {
                lines.append(listItem(depth, "\(key): []"))
            } else if items.allSatisfy(\.isScalar) {
                lines.append(listItem(depth, key + inline(items, key: nil)))
            } else if items.allSatisfy({ $0.objectValue != nil }), let fields = tabularFields(items) {
                lines.append(listItem(depth, header(items.count, key: firstKey, fields: fields)))
                rows(items, fields: fields, depth: depth + 2, into: &lines)
            } else {
                lines.append(listItem(depth, key + header(items.count, key: nil)))
                for item in items { listItemLines(item, depth: depth + 2, into: &lines) }
            }
        case .object(let nested):
            lines.append(listItem(depth, "\(key):"))
            if !nested.isEmpty { objectLines(nested, depth: depth + 2, into: &lines) }
        default:
            lines.append(listItem(depth, "\(key): \(primitive(firstValue))"))
        }
        if !rest.isEmpty { objectLines(rest, depth: depth + 1, into: &lines) }
    }

    // MARK: Pieces

    private static func header(_ count: Int, key: String?, fields: [String]? = nil) -> String {
        var text = key.map(encodeKey) ?? ""
        text += "[\(count)]"
        if let fields { text += "{" + fields.map(encodeKey).joined(separator: ",") + "}" }
        return text + ":"
    }

    private static func inline(_ items: [JSON], key: String?) -> String {
        let head = header(items.count, key: key)
        return items.isEmpty ? head : head + " " + items.map(primitive).joined(separator: ",")
    }

    private static func line(_ depth: Int, _ content: String) -> String {
        String(repeating: "  ", count: depth) + content
    }

    private static func listItem(_ depth: Int, _ content: String) -> String {
        line(depth, "- " + content)
    }

    static func primitive(_ value: JSON) -> String {
        switch value {
        case .null: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let number): return number.isFinite ? JSONWriter.number(number) : "null"
        case .string(let text): return isSafeUnquoted(text) ? text : quote(text)
        case .array, .object: return ""
        }
    }

    private static func encodeKey(_ key: String) -> String {
        isValidKey(key) ? key : quote(key)
    }

    private static func isValidKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, first.isASCIILetter || first == "_" else { return false }
        return key.unicodeScalars.allSatisfy { $0.isASCIILetter || $0.isASCIIDigit || $0 == "_" || $0 == "." }
    }

    private static func isSafeUnquoted(_ text: String) -> Bool {
        guard !text.isEmpty, text == text.trimmingCharacters(in: .whitespaces) else { return false }
        if ["true", "false", "null"].contains(text) || isNumericLike(text) { return false }
        if text.hasPrefix("-") { return false }
        return !text.unicodeScalars.contains {
            [":", "\"", "\\", "[", "]", "{", "}", ","].contains($0) || $0.value < 0x20
        }
    }

    private static func isNumericLike(_ text: String) -> Bool {
        text.range(of: #"^-?\d+(?:\.\d+)?(?:e[+-]?\d+)?$"#, options: [.regularExpression, .caseInsensitive]) != nil
            || text.range(of: #"^0\d+$"#, options: .regularExpression) != nil
    }

    private static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += "\\u" + String(format: "%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

extension Unicode.Scalar {
    var isASCIILetter: Bool { ("a"..."z").contains(self) || ("A"..."Z").contains(self) }
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
