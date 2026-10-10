import Foundation

/// Output formats every command supports.
public enum Format: String, CaseIterable, Sendable {
    case toon, json, yaml, md, jsonl
}

/// Serializes command output.
public enum Formatter {
    /// Formats a value. `nil` and `null` produce an empty string.
    public static func format(_ value: JSON?, _ format: Format = .toon) -> String {
        guard let value, !value.isNull else { return "" }
        switch format {
        case .json:
            if let text = value.stringValue {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("{") || trimmed.hasPrefix("["), let parsed = try? JSONParser.parse(text) {
                    return JSONWriter.stringify(parsed, indent: 2)
                }
            }
            return JSONWriter.stringify(value, indent: 2)
        case .yaml: return Yaml.stringify(value)
        case .md: return markdown(value, path: [])
        case .jsonl:
            if let items = value.arrayValue { return items.map { JSONWriter.stringify($0) }.joined(separator: "\n") }
            return JSONWriter.stringify(value)
        case .toon:
            return value.isScalar ? value.plainText : Toon.encode(value)
        }
    }

    // MARK: Markdown

    private static func markdown(_ value: JSON, path: [String]) -> String {
        if value.isScalar {
            return path.isEmpty ? value.plainText : "## \(path.joined(separator: "."))\n\n\(value.plainText)"
        }
        if let items = value.arrayValue {
            if isArrayOfObjects(items) {
                let table = columnarTable(items)
                return path.isEmpty ? table : "## \(path.joined(separator: "."))\n\n\(table)"
            }
            return markdown(.string(value.plainText), path: path)
        }
        let object = value.objectValue!
        if path.isEmpty, isFlat(object) { return keyValueTable(object) }
        let needsHeadings = !path.isEmpty || object.count > 1 || object.values.contains { !$0.isScalar }
        guard needsHeadings else { return keyValueTable(object) }
        return object.map { key, child in
            let childPath = path + [key]
            let heading = "## \(childPath.joined(separator: "."))"
            if child.isScalar { return "\(heading)\n\n\(child.plainText)" }
            if let items = child.arrayValue, isArrayOfObjects(items) { return "\(heading)\n\n\(columnarTable(items))" }
            if let nested = child.objectValue {
                return isFlat(nested) ? "\(heading)\n\n\(keyValueTable(nested))" : markdown(child, path: childPath)
            }
            return "\(heading)\n\n\(child.plainText)"
        }.joined(separator: "\n\n")
    }

    private static func isFlat(_ object: JSONObject) -> Bool {
        object.values.allSatisfy(\.isScalar)
    }

    private static func isArrayOfObjects(_ items: [JSON]) -> Bool {
        !items.isEmpty && items.allSatisfy { $0.objectValue != nil }
    }

    private static func table(_ headers: [String], _ rows: [[String]]) -> String {
        let widths = headers.indices.map { column in
            max(headers[column].count, rows.map { column < $0.count ? $0[column].count : 0 }.max() ?? 0)
        }
        func pad(_ text: String, _ column: Int) -> String {
            text + String(repeating: " ", count: widths[column] - text.count)
        }
        let head = "| " + headers.indices.map { pad(headers[$0], $0) }.joined(separator: " | ") + " |"
        let separator = "|" + widths.map { String(repeating: "-", count: $0 + 2) }.joined(separator: "|") + "|"
        let body = rows.map { row in
            "| " + headers.indices.map { pad($0 < row.count ? row[$0] : "", $0) }.joined(separator: " | ") + " |"
        }
        return ([head, separator] + body).joined(separator: "\n")
    }

    private static func keyValueTable(_ object: JSONObject) -> String {
        table(["Key", "Value"], object.map { [$0.key, $0.value.plainText] })
    }

    private static func columnarTable(_ items: [JSON]) -> String {
        var keys: [String] = []
        for item in items {
            for key in item.objectValue!.keys where !keys.contains(key) { keys.append(key) }
        }
        let rows = items.map { item in
            keys.map { key -> String in
                guard let value = item[key], !value.isNull else { return "" }
                return value.plainText
            }
        }
        return table(keys, rows)
    }
}
