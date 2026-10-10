import Foundation

/// Minimal YAML 1.2 emitter matching the defaults of the `yaml` npm package that incur uses.
enum Yaml {
    static func stringify(_ value: JSON) -> String {
        var lines: [String] = []
        switch value {
        case .object(let object) where !object.isEmpty: objectLines(object, indent: 0, into: &lines)
        case .array(let items) where !items.isEmpty: arrayLines(items, indent: 0, into: &lines)
        default: lines.append(scalar(value, indent: 0))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func objectLines(_ object: JSONObject, indent: Int, into lines: inout [String]) {
        let pad = String(repeating: " ", count: indent)
        for (key, value) in object {
            let name = encodeKey(key)
            switch value {
            case .object(let nested) where !nested.isEmpty:
                lines.append("\(pad)\(name):")
                objectLines(nested, indent: indent + 2, into: &lines)
            case .array(let items) where !items.isEmpty:
                lines.append("\(pad)\(name):")
                arrayLines(items, indent: indent + 2, into: &lines)
            default:
                lines.append("\(pad)\(name): \(scalar(value, indent: indent + 2))")
            }
        }
    }

    private static func arrayLines(_ items: [JSON], indent: Int, into lines: inout [String]) {
        let pad = String(repeating: " ", count: indent)
        for item in items {
            switch item {
            case .object(let object) where !object.isEmpty:
                var nested: [String] = []
                objectLines(object, indent: indent + 2, into: &nested)
                nested[0] = pad + "- " + nested[0].dropFirst(indent + 2)
                lines.append(contentsOf: nested)
            case .array(let inner) where !inner.isEmpty:
                var nested: [String] = []
                arrayLines(inner, indent: indent + 2, into: &nested)
                nested[0] = pad + "- " + nested[0].dropFirst(indent + 2)
                lines.append(contentsOf: nested)
            default:
                lines.append("\(pad)- \(scalar(item, indent: indent + 2))")
            }
        }
    }

    private static func scalar(_ value: JSON, indent: Int) -> String {
        switch value {
        case .null: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let number):
            if number.isNaN { return ".nan" }
            if number.isInfinite { return number > 0 ? ".inf" : "-.inf" }
            return JSONWriter.number(number)
        case .array: return "[]"
        case .object: return "{}"
        case .string(let text): return string(text, indent: indent)
        }
    }

    private static func encodeKey(_ text: String) -> String {
        needsQuotes(text) ? JSONWriter.quote(text) : text
    }

    private static func string(_ text: String, indent: Int) -> String {
        if text.contains("\n"), !text.hasPrefix(" "), text.unicodeScalars.allSatisfy({ $0.value >= 0x20 || $0 == "\n" }) {
            let pad = String(repeating: " ", count: max(indent, 0))
            let chomp = text.hasSuffix("\n") ? (text.hasSuffix("\n\n") ? "+" : "") : "-"
            let body = (text.hasSuffix("\n") ? String(text.dropLast()) : text)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.isEmpty ? "" : pad + $0 }
            return (["|" + chomp] + body).joined(separator: "\n")
        }
        return needsQuotes(text) ? JSONWriter.quote(text) : text
    }

    private static func needsQuotes(_ text: String) -> Bool {
        guard !text.isEmpty, text == text.trimmingCharacters(in: .whitespaces) else { return true }
        if looksLikeScalar(text) { return true }
        if let first = text.first, "-?:,[]{}#&*!|>'\"%@`".contains(first) {
            let rest = text.dropFirst()
            let safeIndicator = "-?:".contains(first) && !rest.isEmpty && rest.first != " "
            if !safeIndicator { return true }
        }
        if text.contains(": ") || text.contains(" #") || text.hasSuffix(":") { return true }
        return text.unicodeScalars.contains { $0.value < 0x20 || $0 == "\u{7F}" }
    }

    /// Strings YAML 1.2 core schema would read back as something other than a string.
    private static func looksLikeScalar(_ text: String) -> Bool {
        let patterns = [
            #"^(?:null|Null|NULL|~|true|True|TRUE|false|False|FALSE)$"#,
            #"^[-+]?[0-9]+$"#,
            #"^0o[0-7]+$"#,
            #"^0x[0-9a-fA-F]+$"#,
            #"^[-+]?(?:\.[0-9]+|[0-9]+(?:\.[0-9]*)?)(?:[eE][-+]?[0-9]+)?$"#,
            #"^[-+]?\.(?:inf|Inf|INF)$"#,
            #"^\.(?:nan|NaN|NAN)$"#,
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }
}
