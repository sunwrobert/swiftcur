import CryptoKit
import Foundation

/// A command flattened for manifests and skill files.
struct CommandInfo {
    var name: String?
    var description: String?
    var args: Shape?
    var env: Shape?
    var hint: String?
    var options: Shape?
    var output: Schema?
    var examples: [(command: String, description: String?)] = []
}

let destructiveHint = "Confirm with the user before executing this destructive command."

extension Runtime {
    /// Every leaf command in name order, with group descriptions collected.
    func skillCommands(_ commands: Commands, prefix: [String], groups: inout [(String, String)], root: Command?) -> [CommandInfo] {
        var result: [CommandInfo] = []
        if let root { result.append(info(root, path: [])) }
        for (name, entry) in commands.canonical {
            let path = prefix + [name]
            switch entry {
            case .command(let command): result.append(info(command, path: path))
            case .group(let group):
                if let description = group.description { groups.append((path.joined(separator: " "), description)) }
                if let root = group.root { result.append(info(root, path: path)) }
                result += skillCommands(group.commands, prefix: path, groups: &groups, root: nil)
            case .alias: continue
            }
        }
        return result.sorted { localeCompare($0.name ?? "", $1.name ?? "") < 0 }
    }

    private func info(_ command: Command, path: [String]) -> CommandInfo {
        var hint = command.hint
        if command.isDestructive {
            if let existing = hint {
                if !existing.contains(destructiveHint) { hint = "\(existing) \(destructiveHint)" }
            } else {
                hint = destructiveHint
            }
        }
        let name = path.isEmpty ? nil : path.joined(separator: " ")
        return CommandInfo(name: name, description: command.description, args: command.args, env: command.env, hint: hint,
                           options: command.options, output: command.output,
                           examples: command.examples.map { example in
                               let base = name ?? ""
                               let command = path.isEmpty ? example.suffix
                                   : example.suffix.isEmpty ? base : "\(base) \(example.suffix)"
                               return (command, example.description)
                           })
    }

    // MARK: --llms

    func writeManifest(_ flags: BuiltinFlags, _ filtered: [String]) -> Int32 {
        var scoped = cli.commands
        var prefix: [String] = []
        var description = cli.description
        var root = cli.root
        for token in filtered {
            guard let entry = scoped.resolved(token) else { break }
            if case .group(let group) = entry {
                scoped = group.commands
                description = group.description
                root = group.root
                prefix.append(token)
            } else if case .command(let command) = entry {
                var single = Commands()
                single.set(token, .command(command))
                scoped = single
                root = nil
                break
            }
        }
        if prefix.isEmpty { root = cli.root }
        let scopedName = prefix.isEmpty ? name : "\(name) \(prefix.joined(separator: " "))"
        var groups: [(String, String)] = []
        let markdown = !flags.formatExplicit || flags.format == .md

        if flags.llmsFull {
            if markdown {
                let commands = skillCommands(scoped, prefix: [], groups: &groups, root: prefix.isEmpty ? root : nil)
                let entries = prefix.isEmpty ? commands : commands + (root.map { [info($0, path: [])] } ?? [])
                writeln(SkillFile.generate(scopedName, entries.sorted { localeCompare($0.name ?? "", $1.name ?? "") < 0 }, groups))
            } else {
                writeln(Formatter.format(fullManifest(scoped, prefix: prefix, root: root), flags.format))
            }
            return 0
        }
        if markdown {
            let commands = skillCommands(scoped, prefix: [], groups: &groups, root: prefix.isEmpty ? root : nil)
            writeln(SkillFile.index(scopedName, commands, description: description))
        } else {
            writeln(Formatter.format(indexManifest(scoped, prefix: prefix, root: root), flags.format))
        }
        return 0
    }

    private func indexManifest(_ commands: Commands, prefix: [String], root: Command?) -> JSON {
        var entries = indexEntries(commands, prefix)
        if let root, !prefix.isEmpty {
            var entry: JSONObject = ["name": .string(prefix.joined(separator: " "))]
            if let description = root.description { entry["description"] = .string(description) }
            entries.append(.object(entry))
        }
        return manifest(entries)
    }

    private func indexEntries(_ commands: Commands, _ prefix: [String]) -> [JSON] {
        commands.canonical.flatMap { name, entry -> [JSON] in
            let path = prefix + [name]
            let label = JSON.string(path.joined(separator: " "))
            switch entry {
            case .command(let command):
                var object: JSONObject = ["name": label]
                if let description = command.description { object["description"] = .string(description) }
                return [.object(object)]
            case .group(let group):
                var result: [JSON] = []
                if let root = group.root {
                    var object: JSONObject = ["name": label]
                    if let description = root.description { object["description"] = .string(description) }
                    result.append(.object(object))
                }
                return result + indexEntries(group.commands, path)
            case .alias: return []
            }
        }
    }

    private func fullManifest(_ commands: Commands, prefix: [String], root: Command?) -> JSON {
        var entries = fullEntries(commands, prefix)
        if let root, !prefix.isEmpty { entries.append(manifestEntry(prefix, root)) }
        return manifest(entries)
    }

    private func fullEntries(_ commands: Commands, _ prefix: [String]) -> [JSON] {
        commands.canonical.flatMap { name, entry -> [JSON] in
            let path = prefix + [name]
            switch entry {
            case .command(let command): return [manifestEntry(path, command)]
            case .group(let group):
                return (group.root.map { [manifestEntry(path, $0)] } ?? []) + fullEntries(group.commands, path)
            case .alias: return []
            }
        }
    }

    private func manifestEntry(_ path: [String], _ command: Command) -> JSON {
        let name = path.joined(separator: " ")
        var object: JSONObject = ["name": .string(name)]
        if let description = command.description { object["description"] = .string(description) }
        var schema = JSONObject()
        if let args = command.args { schema["args"] = .object(Schema.objectSchema(args)) }
        if let env = command.env { schema["env"] = .object(Schema.objectSchema(env)) }
        if let options = command.options { schema["options"] = .object(Schema.objectSchema(options)) }
        if let output = command.output { schema["output"] = output.jsonSchema }
        if !schema.isEmpty { object["schema"] = .object(schema) }
        if !command.examples.isEmpty {
            object["examples"] = .array(command.examples.map { example in
                var entry: JSONObject = ["command": .string(example.suffix.isEmpty ? name : "\(name) \(example.suffix)")]
                if let description = example.description { entry["description"] = .string(description) }
                return .object(entry)
            })
        }
        return .object(object)
    }

    private func manifest(_ entries: [JSON]) -> JSON {
        var object: JSONObject = [
            "version": "incur.v1",
            "commands": .array(entries.sorted { localeCompare($0["name"]?.stringValue ?? "", $1["name"]?.stringValue ?? "") < 0 }),
        ]
        if let globals = cli.globals { object["globals"] = .object(Schema.objectSchema(globals)) }
        return .object(object)
    }
}

/// Markdown skill files and the `--llms` index.
enum SkillFile {
    struct File {
        var dir: String
        var content: String
    }

    static func index(_ name: String, _ commands: [CommandInfo], description: String?) -> String {
        var lines = ["# \(name)"]
        if let description { lines += ["", description] }
        lines += ["", "| Command | Description |", "|---------|-------------|"]
        for command in commands {
            lines.append("| `\(signature(name, command))` | \(command.description ?? "") |")
        }
        lines += ["", "Run `\(name) --llms-full` for full manifest. Run `\(name) <command> --schema` for argument details."]
        return lines.joined(separator: "\n")
    }

    private static func signature(_ cli: String, _ command: CommandInfo) -> String {
        let base = command.name.map { "\(cli) \($0)" } ?? cli
        guard let args = command.args else { return base }
        let names = args.fields.map { field -> String in
            let label = field.schema.isArray ? "\(field.name)..." : field.name
            return field.schema.isOptional ? "[\(label)]" : "<\(label)>"
        }
        return "\(base) \(names.joined(separator: " "))"
    }

    static func generate(_ name: String, _ commands: [CommandInfo], _ groups: [(String, String)]) -> String {
        guard !groups.isEmpty || commands.contains(where: { $0.name?.contains(" ") == false }) || true else { return "" }
        var sections = ["# \(name)"]
        var lastGroup: String?
        let groupMap = Dictionary(groups, uniquingKeysWith: { first, _ in first })
        for command in commands {
            let segment = command.name.map { String($0.split(separator: " ")[0]) } ?? ""
            if segment != lastGroup {
                lastGroup = segment
                if !segment.isEmpty {
                    let heading = "## \(name) \(segment)"
                    sections.append(groupMap[segment].map { "\(heading)\n\n\($0)" } ?? heading)
                }
            }
            sections.append(body(name, command, level: segment.isEmpty ? 2 : 3))
        }
        return sections.joined(separator: "\n\n")
    }

    /// Splits commands into one skill file per group at `depth`.
    static func split(_ name: String, _ commands: [CommandInfo], depth: Int, _ groups: [(String, String)]) -> [File] {
        let groupMap = Dictionary(groups, uniquingKeysWith: { first, _ in first })
        if depth == 0 { return [File(dir: "", content: group(name, title: name, commands, groupMap, prefix: name))] }
        var order: [String] = []
        var buckets: [String: [CommandInfo]] = [:]
        for command in commands {
            let key = command.name.map { $0.split(separator: " ").prefix(depth).joined(separator: "-") } ?? slugify(name)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(command)
        }
        return order.sorted { localeCompare($0, $1) < 0 }.map { dir in
            let items = buckets[dir]!
            let prefix = items[0].name.map { $0.split(separator: " ").prefix(depth).joined(separator: " ") } ?? ""
            let title = prefix.isEmpty ? name : "\(name) \(prefix)"
            return File(dir: dir, content: group(name, title: title, items, groupMap, prefix: prefix.isEmpty ? nil : prefix))
        }
    }

    private static func group(_ cli: String, title: String, _ commands: [CommandInfo], _ groups: [String: String],
                              prefix: String?) -> String {
        let fallback = commands.count == 1 ? commands[0].description : nil
        let groupDescription = prefix.flatMap { groups[$0] } ?? fallback
        let description = groupDescription.map {
            "\($0.hasSuffix(".") ? String($0.dropLast()) : $0). Run `\(title) --help` for usage details."
        } ?? "Run `\(title) --help` for usage details."
        let frontmatter = Yaml.stringify(["name": .string(slugify(title)), "description": .string(description),
                                          "requires_bin": .string(cli), "command": .string(title)])
        let bodies = commands.map { body(cli, $0) }.joined(separator: "\n\n---\n\n")
        return "---\n\(frontmatter.trimmingCharacters(in: .newlines))\n---\n\n\(bodies)"
    }

    private static func body(_ cli: String, _ command: CommandInfo, level: Int = 1) -> String {
        let fullName = command.name.map { "\(cli) \($0)" } ?? cli
        let heading = String(repeating: "#", count: level)
        let sub = String(repeating: "#", count: level + 1)
        var sections = ["\(heading) \(fullName)" + (command.description.map { "\n\n\($0)" } ?? "")]

        if let args = command.args {
            let rows = args.fields.map { "| `\($0.name)` | `\(jsonType($0.schema))` | \($0.schema.isOptional ? "no" : "yes") | \($0.schema.description ?? "") |" }
            sections.append("\(sub) Arguments\n\n| Name | Type | Required | Description |\n|------|------|----------|-------------|\n" + rows.joined(separator: "\n"))
        }
        if let env = command.env {
            let rows = env.fields.map { field -> String in
                let value = field.schema.defaultValue.map(\.plainText).flatMap { $0.isEmpty ? nil : "`\($0)`" } ?? ""
                return "| `\(field.name)` | `\(jsonType(field.schema))` | \(field.schema.isOptional ? "no" : "yes") | \(value) | \(field.schema.description ?? "") |"
            }
            sections.append("\(sub) Environment Variables\n\n| Name | Type | Required | Default | Description |\n|------|------|----------|---------|-------------|\n" + rows.joined(separator: "\n"))
        }
        if let options = command.options {
            let rows = options.fields.map { field -> String in
                let value = field.schema.defaultValue.map(\.plainText).flatMap { $0.isEmpty ? nil : "`\($0)`" } ?? ""
                let description = (field.schema.isDeprecated ? "**Deprecated.** " : "") + (field.schema.description ?? "")
                return "| `--\(field.name)` | `\(jsonType(field.schema))` | \(value) | \(description) |"
            }
            sections.append("\(sub) Options\n\n| Flag | Type | Default | Description |\n|------|------|---------|-------------|\n" + rows.joined(separator: "\n"))
        }
        if let output = command.output {
            let schema = output.jsonSchema
            if let table = table(schema, prefix: "") {
                sections.append("\(sub) Output\n\n\(table)")
            } else {
                sections.append("\(sub) Output\n\nType: `\(typeName(schema))`")
            }
        }
        if !command.examples.isEmpty {
            let lines = command.examples.map { ($0.description.map { "# \($0)\n" } ?? "") + "\(cli) \($0.command)" }
            sections.append("\(sub) Examples\n\n```sh\n\(lines.joined(separator: "\n\n"))\n```")
        }
        if let hint = command.hint { sections.append("> \(hint)") }
        return sections.joined(separator: "\n\n")
    }

    private static func table(_ schema: JSON, prefix: String) -> String? {
        guard schema["type"]?.stringValue == "object", let properties = schema["properties"]?.objectValue, !properties.isEmpty else {
            return nil
        }
        let required = Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        var rows: [String] = []
        for (key, property) in properties {
            let name = prefix.isEmpty ? key : "\(prefix).\(key)"
            rows.append("| `\(name)` | `\(typeName(property))` | \(required.contains(key) ? "yes" : "no") | \(property["description"]?.stringValue ?? "") |")
            if property["type"]?.stringValue == "object", let nested = table(property, prefix: name) {
                rows += nested.split(separator: "\n").dropFirst(2).map(String.init)
            }
            if property["type"]?.stringValue == "array", let items = property["items"], items["type"]?.stringValue == "object",
               let nested = table(items, prefix: "\(name)[]") {
                rows += nested.split(separator: "\n").dropFirst(2).map(String.init)
            }
        }
        return "| Field | Type | Required | Description |\n|-------|------|----------|-------------|\n" + rows.joined(separator: "\n")
    }

    private static func jsonType(_ schema: Schema) -> String { typeName(schema.jsonSchema) }

    private static func typeName(_ schema: JSON) -> String {
        guard let type = schema["type"]?.stringValue else { return "unknown" }
        return type == "integer" ? "number" : type
    }

    /// Short stable hash of command structure, for stale-skill detection.
    static func hash(_ commands: [CommandInfo]) -> String {
        let data: [JSON] = commands.map { command in
            var object = JSONObject()
            if let name = command.name { object["name"] = .string(name) }
            if let description = command.description { object["description"] = .string(description) }
            if let hint = command.hint { object["hint"] = .string(hint) }
            if let args = command.args { object["args"] = .object(Schema.objectSchema(args)) }
            if let env = command.env { object["env"] = .object(Schema.objectSchema(env)) }
            if let options = command.options { object["options"] = .object(Schema.objectSchema(options)) }
            if let output = command.output { object["output"] = output.jsonSchema }
            return .object(object)
        }
        let digest = SHA256.hash(data: Data(JSONWriter.stringify(.array(data)).utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    static func slugify(_ text: String) -> String {
        var slug = text.lowercased().replacingOccurrences(of: "[^a-z0-9-]+", with: "-", options: .regularExpression)
        slug = slug.replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
        return slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// `name` and `description` from a skill file's YAML frontmatter.
    static func frontmatter(_ content: String) -> (name: String?, description: String?) {
        guard content.hasPrefix("---"), let end = content.range(of: "\n---", range: content.index(content.startIndex, offsetBy: 3)..<content.endIndex) else {
            return (nil, nil)
        }
        var name: String?, description: String?
        for line in content[content.index(content.startIndex, offsetBy: 3)..<end.lowerBound].split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), let parsed = try? JSONParser.parse(value).stringValue {
                value = parsed
            } else if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
                value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            }
            if key == "name" { name = value } else if key == "description" { description = value }
        }
        return (name, description)
    }
}
