import Foundation

/// A suggested command after the CLI name has been folded in.
struct FormattedCta {
    var command: String
    var description: String?

    var json: JSON {
        var object: JSONObject = ["command": .string(command)]
        if let description { object["description"] = .string(description) }
        return .object(object)
    }
}

struct FormattedCtaBlock {
    var description: String
    var commands: [FormattedCta]

    var json: JSON {
        ["description": .string(description), "commands": .array(commands.map(\.json))]
    }

    static func make(_ name: String, _ block: CtaBlock?) -> FormattedCtaBlock? {
        guard let block, !block.commands.isEmpty else { return nil }
        let description = block.description ?? (block.commands.count == 1 ? "Suggested command:" : "Suggested commands:")
        return FormattedCtaBlock(description: description, commands: block.commands.map { cta in
            let hasPrefix = cta.command == name || cta.command.hasPrefix("\(name) ")
            var command = (hasPrefix ? "" : "\(name) ") + cta.command
            for (key, value) in cta.args { command += value == .bool(true) ? " <\(key)>" : " \(value.plainText)" }
            for (key, value) in cta.options {
                command += value == .bool(true) ? " --\(key) <\(key)>" : " --\(key) \(value.plainText)"
            }
            return FormattedCta(command: command, description: cta.description)
        })
    }

    static func merge(_ blocks: FormattedCtaBlock?...) -> FormattedCtaBlock? {
        let defined = blocks.compactMap { $0 }
        guard let first = defined.first else { return nil }
        return FormattedCtaBlock(description: first.description, commands: defined.flatMap(\.commands))
    }

    /// Plain text for MCP tool output.
    var text: String {
        ([description] + commands.map { "  \($0.command)" + ($0.description.map { " - \($0)" } ?? "") })
            .joined(separator: "\n")
    }

    /// TTY rendering, aligned with `#` comments.
    var human: String {
        let width = commands.map(\.command.count).max() ?? 0
        let lines = commands.map { cta -> String in
            guard let description = cta.description else { return "  \(cta.command)" }
            return "  \(cta.command)  \(String(repeating: " ", count: width - cta.command.count))# \(description)"
        }
        return (["", description] + lines).joined(separator: "\n")
    }
}

enum HumanError {
    static func format(code: String, message: String, fieldErrors: [FieldError]? = nil) -> String {
        let prefix = code == "UNKNOWN" || code == "COMMAND_NOT_FOUND" ? "Error" : "Error (\(code))"
        var out = "\(prefix): \(message)"
        for field in fieldErrors ?? [] { out += "\n  \(field.path): \(field.message)" }
        return out
    }
}

/// `--filter-output` paths: `foo,bar.baz,items[0,3].name`.
enum Filter {
    enum Segment: Equatable {
        case key(String)
        case slice(Int, Int)
    }

    static func parse(_ expression: String) -> [[Segment]] {
        var tokens: [String] = []
        var current = ""
        var depth = 0
        for character in expression {
            if character == "[" { depth += 1 } else if character == "]" { depth -= 1 }
            if character == ",", depth == 0 {
                tokens.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }

        return tokens.map { token in
            var path: [Segment] = []
            var remaining = Substring(token)
            while !remaining.isEmpty {
                guard let open = remaining.firstIndex(of: "[") else {
                    path += remaining.split(separator: ".").map { .key(String($0)) }
                    break
                }
                path += remaining[..<open].split(separator: ".").map { .key(String($0)) }
                let close = remaining[open...].firstIndex(of: "]") ?? remaining.endIndex
                let bounds = remaining[remaining.index(after: open)..<close].split(separator: ",", omittingEmptySubsequences: false)
                let start = Int(jsNumber(String(bounds.first ?? "")))
                let end = bounds.count > 1 ? Int(jsNumber(String(bounds[1]))) : 0
                path.append(.slice(start, end))
                remaining = close < remaining.endIndex ? remaining[remaining.index(after: close)...] : ""
                if remaining.hasPrefix(".") { remaining = remaining.dropFirst() }
            }
            return path
        }
    }

    static func apply(_ data: JSON, _ paths: [[Segment]]) -> JSON? {
        guard !paths.isEmpty else { return data }
        if paths.count == 1, paths[0].count == 1, case .key(let key) = paths[0][0] {
            if let items = data.arrayValue { return .array(items.map { apply($0, paths) ?? .null }) }
            guard let object = data.objectValue else { return nil }
            guard let value = object[key] else { return nil }
            return value.isScalar ? value : .object([key: value])
        }
        if let items = data.arrayValue { return .array(items.map { apply($0, paths) ?? .null }) }
        var result = JSONObject()
        for path in paths { merge(&result, data, path, 0) }
        return .object(result)
    }

    private static func merge(_ target: inout JSONObject, _ data: JSON, _ segments: [Segment], _ index: Int) {
        guard index < segments.count, let object = data.objectValue, case .key(let key) = segments[index],
              let value = object[key] else { return }
        if index + 1 >= segments.count {
            target[key] = value
            return
        }
        if case .slice(let start, let end) = segments[index + 1] {
            guard let items = value.arrayValue else { return }
            let sliced = slice(items, start, end)
            if index + 2 >= segments.count {
                target[key] = .array(sliced)
                return
            }
            target[key] = .array(sliced.map { item in
                var sub = JSONObject()
                merge(&sub, item, segments, index + 2)
                return .object(sub)
            })
            return
        }
        guard !value.isScalar else { return }
        var nested = target[key]?.objectValue ?? JSONObject()
        merge(&nested, value, segments, index + 1)
        target[key] = .object(nested)
    }

    /// JavaScript `Array.prototype.slice`.
    private static func slice(_ items: [JSON], _ start: Int, _ end: Int) -> [JSON] {
        let count = items.count
        let from = start < 0 ? max(count + start, 0) : min(start, count)
        let to = end < 0 ? max(count + end, 0) : min(end, count)
        return from < to ? Array(items[from..<to]) : []
    }
}
