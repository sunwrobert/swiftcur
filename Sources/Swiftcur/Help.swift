import Foundation

/// Help text for CLIs, groups, and commands.
enum Help {
    struct Item {
        var name: String
        var description: String?
    }

    struct Globals {
        var shape: Shape
        var alias: [String: String]
    }

    struct RootOptions {
        var aliases: [String] = []
        var configFlag: String?
        var commands: [Item] = []
        var description: String?
        var globals: Globals?
        var hideSkills = false
        var root = false
        var version: String?
    }

    struct CommandOptions {
        var alias: [String: String] = [:]
        var aliases: [String] = []
        var args: Shape?
        var configFlag: String?
        var commands: [Item] = []
        var description: String?
        var env: Shape?
        var environment: [String: String] = [:]
        var globals: Globals?
        var examples: [(command: String, description: String?)] = []
        var hint: String?
        var hideGlobalOptions = false
        var hideSkills = false
        var options: Shape?
        var root = false
        var usage: [Usage] = []
        var version: String?
    }

    static func formatRoot(_ name: String, _ options: RootOptions) -> String {
        var lines = [title(name, options.version, options.description), "", "Usage: \(name) <command>"]
        if !options.aliases.isEmpty { lines.append("Aliases: \(options.aliases.joined(separator: ", "))") }
        if !options.commands.isEmpty {
            lines += ["", "Commands:"] + columns(options.commands.map { ($0.name, $0.description) })
        }
        lines += globalOptionLines(root: options.root, configFlag: options.configFlag, globals: options.globals,
                                   hideSkills: options.hideSkills)
        return lines.joined(separator: "\n")
    }

    static func formatCommand(_ name: String, _ options: CommandOptions) -> String {
        var lines = [title(name, options.version, options.description), ""]

        if !options.usage.isEmpty {
            let usageLines = options.usage.map { usage -> String in
                var parts: [String] = []
                if let prefix = usage.prefix { parts.append(prefix) }
                parts.append(name)
                parts += usage.args.map { "<\($0)>" }
                parts += usage.options.map { "--\($0) <\($0)>" }
                if let suffix = usage.suffix { parts.append(suffix) }
                return parts.joined(separator: " ")
            }
            lines.append("Usage: \(usageLines[0])")
            lines += usageLines.dropFirst().map { String(repeating: " ", count: 7) + $0 }
        } else {
            let commandSuffix = options.commands.isEmpty ? "" : " | <command>"
            lines.append("Usage: \(synopsis(name, options.args))\(options.options == nil ? "" : " [options]")\(commandSuffix)")
        }
        if !options.aliases.isEmpty { lines.append("Aliases: \(options.aliases.joined(separator: ", "))") }

        if let args = options.args, !args.isEmpty {
            lines += ["", "Arguments:"] + columns(args.fields.map { ($0.name, $0.schema.description ?? "") })
        }
        if let shape = options.options {
            let entries = optionEntries(shape, options.alias)
            if !entries.isEmpty { lines += ["", "Options:"] + columns(entries) }
        }
        if !options.examples.isEmpty {
            let commands = options.examples.map { $0.command.isEmpty ? name : "\(name) \($0.command)" }
            let width = commands.map(\.count).max() ?? 0
            lines += ["", "Examples:"]
            for (command, example) in zip(commands, options.examples) {
                if let description = example.description {
                    lines.append("  \(pad(command, width))  # \(description)")
                } else {
                    lines.append("  \(command)")
                }
            }
        }
        if let hint = options.hint { lines += ["", hint] }
        if !options.commands.isEmpty {
            lines += ["", "Commands:"] + columns(options.commands.map { ($0.name, $0.description) })
        }
        if !options.hideGlobalOptions {
            lines += globalOptionLines(root: options.root, configFlag: options.configFlag, globals: options.globals,
                                       hideSkills: options.hideSkills)
        }
        if let env = options.env, !env.isEmpty {
            lines += ["", "Environment Variables:"]
            let width = env.names.map(\.count).max() ?? 0
            for field in env.fields {
                var parts = [field.schema.description ?? ""]
                if let value = options.environment[field.name] { parts.append("set: \(redact(value))") }
                if let value = field.schema.defaultValue { parts.append("default: \(value.plainText)") }
                let description = parts.count > 1 ? "\(parts[0]) (\(parts.dropFirst().joined(separator: ", ")))" : parts[0]
                lines.append("  \(pad(field.name, width))  \(description)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Pieces

    private static func title(_ name: String, _ version: String?, _ description: String?) -> String {
        let title = version.map { "\(name)@\($0)" } ?? name
        return description.map { "\(title) \u{2014} \($0)" } ?? title
    }

    static func synopsis(_ name: String, _ args: Shape?) -> String {
        guard let args else { return name }
        let parts = args.fields.map { field -> String in
            let type = field.schema.typeName
            let label = (type.contains("|") ? type : field.name) + (type == "array" ? "..." : "")
            return field.schema.isOptional ? "[\(label)]" : "<\(label)>"
        }
        return ([name] + parts).joined(separator: " ")
    }

    private static func optionEntries(_ shape: Shape, _ alias: [String: String]) -> [(String, String?)] {
        shape.fields.map { field in
            let type = field.schema.typeName
            let hint = type == "boolean" ? "" : " <\(type)>"
            let kebab = toKebab(field.name)
            let flag = alias[field.name].map { "--\(kebab), -\($0)\(hint)" } ?? "--\(kebab)\(hint)"
            var defaultValue = field.schema.defaultValue
            if type == "boolean", defaultValue == .bool(false) { defaultValue = nil }
            if let value = defaultValue, value.arrayValue?.isEmpty == true { defaultValue = nil }
            let prefix = field.schema.isDeprecated ? "[deprecated] " : ""
            let description = prefix + (field.schema.description ?? "")
                + (defaultValue.map { " (default: \($0.plainText))" } ?? "")
            return (flag, description)
        }
    }

    private static func globalOptionLines(root: Bool, configFlag: String?, globals: Globals?, hideSkills: Bool) -> [String] {
        var lines: [String] = []
        if root {
            let builtins = Builtin.all.filter { !hideSkills || $0.name != "skills" }.map { builtin -> (String, String?) in
                if builtin.subcommands.count == 1 {
                    return ("\(builtin.name) \(builtin.subcommands[0].name)", builtin.subcommands[0].description)
                }
                if builtin.subcommands.isEmpty { return (builtin.name, builtin.description) }
                return (builtin.name, "\(builtin.description) (\(builtin.subcommands.map(\.name).joined(separator: ", ")))")
            }
            lines += ["", "Integrations:"] + columns(builtins)
        }
        if let globals {
            let entries = optionEntries(globals.shape, globals.alias)
            if !entries.isEmpty { lines += ["", "Custom Global Options:"] + columns(entries) }
        }
        var flags: [(String, String)] = []
        if let configFlag { flags.append(("--\(configFlag) <path>", "Load JSON option defaults from a file")) }
        flags += [
            ("--filter-output <keys>", "Filter output by key paths (e.g. foo,bar.baz,a[0,3])"),
            ("--format <toon|json|yaml|md|jsonl>", "Output format"),
            ("--help", "Show help"),
            ("--llms, --llms-full", "Print LLM-readable manifest"),
        ]
        if root { flags.append(("--mcp", "Start as MCP stdio server")) }
        if let configFlag { flags.append(("--no-\(configFlag)", "Disable JSON option defaults for this run")) }
        flags += [
            ("--schema", "Show JSON Schema for command"),
            ("--token-count", "Print token count of output (instead of output)"),
            ("--token-limit <n>", "Limit output to n tokens"),
            ("--token-offset <n>", "Skip first n tokens of output"),
            ("--full-output", "Show full output envelope"),
        ]
        if root { flags += [("--update", "Update to latest version"), ("--version", "Show version")] }
        flags.sort { localeCompare($0.0, $1.0) < 0 }
        return lines + ["", "Global Options:"] + columns(flags.map { ($0.0, $0.1) })
    }

    private static func columns(_ rows: [(String, String?)]) -> [String] {
        let width = rows.map(\.0.count).max() ?? 0
        return rows.map { name, description in
            guard let description else { return "  \(name)" }
            return "  \(pad(name, width))  \(description)"
        }
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text + String(repeating: " ", count: max(0, width - text.count))
    }

    private static func redact(_ value: String) -> String {
        value.count <= 4 ? "****" : "****" + value.suffix(4)
    }
}

/// Approximates JavaScript's `localeCompare` for ASCII: punctuation sorts before letters, case-insensitive first.
func localeCompare(_ a: String, _ b: String) -> Int {
    func key(_ text: String) -> [(Int, Int)] {
        text.unicodeScalars.map { scalar in
            let value = Int(scalar.value)
            let lower = Int(Character(scalar).lowercased().unicodeScalars.first!.value)
            let isAlphanumeric = CharacterSet.alphanumerics.contains(scalar)
            let rank = isAlphanumeric ? (scalar.isASCIIDigit ? 1 : 2) : 0
            return (rank * 1_000_000 + lower, value)
        }
    }
    let left = key(a), right = key(b)
    for (l, r) in zip(left, right) where l.0 != r.0 { return l.0 < r.0 ? -1 : 1 }
    if left.count != right.count { return left.count < right.count ? -1 : 1 }
    for (l, r) in zip(left, right) where l.1 != r.1 { return l.1 > r.1 ? -1 : 1 }
    return 0
}
