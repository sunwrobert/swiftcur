import Foundation

/// Parses JSON text into `JSON`, keeping object key order.
enum JSONParser {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func parse(_ text: String) throws -> JSON {
        var parser = State(scalars: Array(text.unicodeScalars))
        parser.skipWhitespace()
        let value = try parser.value()
        parser.skipWhitespace()
        guard parser.index == parser.scalars.count else { throw parser.failure("Unexpected trailing content") }
        return value
    }

    private struct State {
        let scalars: [Unicode.Scalar]
        var index = 0

        func failure(_ message: String) -> Failure {
            Failure(description: "\(message) at position \(index)")
        }

        mutating func skipWhitespace() {
            while index < scalars.count, [" ", "\n", "\r", "\t"].contains(scalars[index]) { index += 1 }
        }

        mutating func value() throws -> JSON {
            guard index < scalars.count else { throw failure("Unexpected end of JSON input") }
            switch scalars[index] {
            case "{": return try object()
            case "[": return try array()
            case "\"": return .string(try string())
            case "t": return try literal("true", .bool(true))
            case "f": return try literal("false", .bool(false))
            case "n": return try literal("null", .null)
            default: return try number()
            }
        }

        mutating func literal(_ word: String, _ result: JSON) throws -> JSON {
            let expected = Array(word.unicodeScalars)
            guard index + expected.count <= scalars.count, Array(scalars[index..<index + expected.count]) == expected else {
                throw failure("Unexpected token")
            }
            index += expected.count
            return result
        }

        mutating func number() throws -> JSON {
            let start = index
            while index < scalars.count, "+-0123456789.eE".unicodeScalars.contains(scalars[index]) { index += 1 }
            let text = String(String.UnicodeScalarView(scalars[start..<index]))
            guard !text.isEmpty, let value = Double(text) else { throw failure("Unexpected token") }
            return .number(value)
        }

        mutating func string() throws -> String {
            index += 1
            var result = String.UnicodeScalarView()
            while index < scalars.count {
                let scalar = scalars[index]
                index += 1
                switch scalar {
                case "\"": return String(result)
                case "\\": result.append(contentsOf: try escape())
                default: result.append(scalar)
                }
            }
            throw failure("Unterminated string")
        }

        mutating func escape() throws -> [Unicode.Scalar] {
            guard index < scalars.count else { throw failure("Unterminated string") }
            let scalar = scalars[index]
            index += 1
            switch scalar {
            case "\"", "\\", "/": return [scalar]
            case "b": return ["\u{08}"]
            case "f": return ["\u{0C}"]
            case "n": return ["\n"]
            case "r": return ["\r"]
            case "t": return ["\t"]
            case "u":
                let high = try hex4()
                if (0xD800...0xDBFF).contains(high), index + 1 < scalars.count, scalars[index] == "\\", scalars[index + 1] == "u" {
                    index += 2
                    let low = try hex4()
                    let combined = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
                    return [Unicode.Scalar(combined) ?? "\u{FFFD}"]
                }
                return [Unicode.Scalar(high) ?? "\u{FFFD}"]
            default: throw failure("Bad escape")
            }
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= scalars.count,
                  let value = UInt32(String(String.UnicodeScalarView(scalars[index..<index + 4])), radix: 16) else {
                throw failure("Bad unicode escape")
            }
            index += 4
            return value
        }

        mutating func array() throws -> JSON {
            index += 1
            var items: [JSON] = []
            skipWhitespace()
            if index < scalars.count, scalars[index] == "]" {
                index += 1
                return .array(items)
            }
            while true {
                skipWhitespace()
                items.append(try value())
                skipWhitespace()
                guard index < scalars.count else { throw failure("Unterminated array") }
                if scalars[index] == "]" {
                    index += 1
                    return .array(items)
                }
                guard scalars[index] == "," else { throw failure("Expected ','") }
                index += 1
            }
        }

        mutating func object() throws -> JSON {
            index += 1
            var object = JSONObject()
            skipWhitespace()
            if index < scalars.count, scalars[index] == "}" {
                index += 1
                return .object(object)
            }
            while true {
                skipWhitespace()
                guard index < scalars.count, scalars[index] == "\"" else { throw failure("Expected property name") }
                let key = try string()
                skipWhitespace()
                guard index < scalars.count, scalars[index] == ":" else { throw failure("Expected ':'") }
                index += 1
                skipWhitespace()
                object[key] = try value()
                skipWhitespace()
                guard index < scalars.count else { throw failure("Unterminated object") }
                if scalars[index] == "}" {
                    index += 1
                    return .object(object)
                }
                guard scalars[index] == "," else { throw failure("Expected ','") }
                index += 1
            }
        }
    }
}

/// Writes JSON the way JavaScript's `JSON.stringify` does.
enum JSONWriter {
    static func stringify(_ value: JSON, indent: Int? = nil) -> String {
        var out = ""
        write(value, indent: indent, depth: 0, into: &out)
        return out
    }

    private static func write(_ value: JSON, indent: Int?, depth: Int, into out: inout String) {
        switch value {
        case .null: out += "null"
        case let .bool(flag): out += flag ? "true" : "false"
        case let .number(number): out += number.isFinite ? self.number(number) : "null"
        case let .string(text): out += quote(text)
        case let .array(items):
            guard !items.isEmpty else { return out += "[]" }
            out += "["
            for (offset, item) in items.enumerated() {
                if offset > 0 { out += "," }
                newline(indent, depth + 1, &out)
                write(item, indent: indent, depth: depth + 1, into: &out)
            }
            newline(indent, depth, &out)
            out += "]"
        case let .object(object):
            guard !object.isEmpty else { return out += "{}" }
            out += "{"
            for (offset, entry) in object.enumerated() {
                if offset > 0 { out += "," }
                newline(indent, depth + 1, &out)
                out += quote(entry.key)
                out += indent == nil ? ":" : ": "
                write(entry.value, indent: indent, depth: depth + 1, into: &out)
            }
            newline(indent, depth, &out)
            out += "}"
        }
    }

    private static func newline(_ indent: Int?, _ depth: Int, _ out: inout String) {
        guard let indent else { return }
        out += "\n" + String(repeating: " ", count: indent * depth)
    }

    static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
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

    /// Formats a number like JavaScript's `Number.prototype.toString`.
    static func number(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value > 0 ? "Infinity" : "-Infinity" }
        if value == 0 { return "0" }
        var text = "\(abs(value))"
        var exponent = 0
        if let marker = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = Int(text[text.index(after: marker)...]) ?? 0
            text = String(text[..<marker])
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let whole = String(parts[0])
        var digits = whole + (parts.count > 1 ? String(parts[1]) : "")
        var point = whole.count + exponent
        while digits.count > 1, digits.hasPrefix("0") {
            digits.removeFirst()
            point -= 1
        }
        while digits.count > 1, digits.hasSuffix("0") { digits.removeLast() }
        let count = digits.count
        let body: String
        if count <= point, point <= 21 {
            body = digits + String(repeating: "0", count: point - count)
        } else if point > 0, point <= 21 {
            body = digits.prefix(point) + "." + digits.dropFirst(point)
        } else if point > -6, point <= 0 {
            body = "0." + String(repeating: "0", count: -point) + digits
        } else {
            let power = point - 1
            let mantissa = count > 1 ? "\(digits.first!).\(digits.dropFirst())" : digits
            body = "\(mantissa)e\(power >= 0 ? "+" : "-")\(abs(power))"
        }
        return value < 0 ? "-" + body : body
    }
}
