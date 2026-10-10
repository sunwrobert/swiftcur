import Foundation

extension Runtime {
    var cwd: String { cli.sync?.cwd ?? FileManager.default.currentDirectoryPath }

    /// Index of a built-in command token in argv, allowing a leading CLI name.
    private func builtinIndex(_ filtered: [String], _ builtin: String) -> Int? {
        if Builtin.find(filtered.first)?.name == builtin { return 0 }
        if filtered.first == name, filtered.count > 1, Builtin.find(filtered[1])?.name == builtin { return 1 }
        return nil
    }

    private func builtinHelp(_ builtin: Builtin) -> String {
        Help.formatRoot("\(name) \(builtin.name)", Help.RootOptions(
            aliases: builtin.aliases, commands: builtin.subcommands.map { Help.Item(name: $0.name, description: $0.description) },
            description: builtin.description
        ))
    }

    private func builtinSubcommandHelp(_ builtin: Builtin, _ sub: Builtin.Subcommand) -> String {
        Help.formatCommand("\(name) \(builtin.name) \(sub.name)", Help.CommandOptions(
            alias: sub.alias, aliases: sub.aliases, description: sub.description, hideGlobalOptions: true, options: sub.options
        ))
    }

    /// Reports a mistyped built-in subcommand. Returns the exit code.
    private func unknownSubcommand(_ builtin: Builtin, _ token: String, argv: [String]) -> Int32 {
        let candidates = builtin.subcommands.flatMap { [$0.name] + $0.aliases }
        let suggestion = suggest(token, candidates)
        let message = "'\(token)' is not a command for '\(name) \(builtin.name)'." + (suggestion.map { " Did you mean '\($0)'?" } ?? "")
        let cta = notFoundCta(suggestion: suggestion, token: token, argv: argv, helpCommand: "\(name) \(builtin.name) --help")
        if human {
            writeln(HumanError.format(code: "COMMAND_NOT_FOUND", message: message))
            writeln(cta.human)
        } else {
            writeln(Formatter.format(["code": "COMMAND_NOT_FOUND", "message": .string(message), "cta": cta.json], .toon))
        }
        return 1
    }

    // MARK: completions

    func handleCompletionsCommand(_ flags: BuiltinFlags, _ filtered: [String]) -> Int32? {
        guard let index = builtinIndex(filtered, "completions") else { return nil }
        let shell = index + 1 < filtered.count ? filtered[index + 1] : nil
        guard let shell, !flags.help else {
            let builtin = Builtin.completions
            writeln(Help.formatCommand("\(name) completions", Help.CommandOptions(
                args: builtin.args, description: builtin.description, hint: Builtin.completionsHint(name), hideGlobalOptions: true
            )))
            return 0
        }
        guard Builtin.shells.contains(shell) else {
            writeln(HumanError.format(code: "INVALID_SHELL", message: "Unknown shell '\(shell)'. Supported: \(Builtin.shells.joined(separator: ", "))"))
            return 1
        }
        writeln(([name] + cli.aliases).map { Completions.register(shell, $0) }.joined(separator: "\n"))
        return 0
    }

    // MARK: skills

    func skillFiles(depth: Int) -> [SkillFile.File] {
        var groups: [(String, String)] = []
        if let description = cli.description { groups.append((name, description)) }
        let commands = skillCommands(cli.commands, prefix: [], groups: &groups, root: cli.root)
        return SkillFile.split(name, commands, depth: depth, groups)
    }

    func skillsHash() -> String {
        var groups: [(String, String)] = []
        return SkillFile.hash(skillCommands(cli.commands, prefix: [], groups: &groups, root: cli.root))
    }

    func staleSkillsNotice(_ filtered: [String]) -> FormattedCtaBlock? {
        guard skillsEnabled, builtinIndex(filtered, "skills") == nil, builtinIndex(filtered, "mcp") == nil,
              let stored = SkillMeta.read(name, io.environment)?.hash,
              !SkillMeta.installed(name, io.environment, cwd: cwd).isEmpty,
              skillsHash() != stored else { return nil }
        return FormattedCtaBlock(description: "Skills are out of date:",
                                 commands: [FormattedCta(command: "\(displayName) skills add", description: "sync outdated skills")])
    }

    /// Hand-written skills matched by `include` patterns: `(name, description, content)`.
    private func includedSkills() -> [(name: String, description: String?, content: String)] {
        guard let include = cli.sync?.include else { return [] }
        var result: [(name: String, description: String?, content: String)] = []
        for pattern in include {
            for file in glob(pattern == "_root" ? "SKILL.md" : "\(pattern)/SKILL.md", in: cwd) {
                guard let content = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
                let meta = SkillFile.frontmatter(content)
                let skillName = pattern == "_root" ? (meta.name ?? name)
                    : ((file as NSString).deletingLastPathComponent as NSString).lastPathComponent
                result.append((skillName, meta.description, content))
            }
        }
        return result
    }

    func handleSkillsCommand(_ flags: BuiltinFlags, _ filtered: [String], argv: [String]) async -> Int32? {
        guard skillsEnabled, let index = builtinIndex(filtered, "skills") else { return nil }
        let builtin = Builtin.skills
        let token = index + 1 < filtered.count ? filtered[index + 1] : nil
        guard let token else {
            writeln(builtinHelp(builtin))
            return 0
        }
        guard let sub = builtin.subcommand(token) else { return unknownSubcommand(builtin, token, argv: argv) }
        if flags.help {
            writeln(builtinSubcommandHelp(builtin, sub))
            return 0
        }
        if sub.name == "list" { return listSkills() }

        let rest = Array(filtered.dropFirst(index + 2))
        var depth = cli.sync?.depth ?? 1
        if let position = rest.firstIndex(of: "--depth"), position + 1 < rest.count {
            depth = Int(jsNumber(rest[position + 1]))
        } else if let token = rest.first(where: { $0.hasPrefix("--depth=") }) {
            depth = Int(jsNumber(String(token.dropFirst(8))))
        }
        let global = !rest.contains("--no-global")
        return syncSkills(depth: depth, global: global, flags: flags)
    }

    private func listSkills() -> Int32 {
        let installed = SkillMeta.installed(name, io.environment, cwd: cwd)
        var skills: [(name: String, description: String?, installed: Bool)] = skillFiles(depth: cli.sync?.depth ?? 1).map { file in
            let meta = SkillFile.frontmatter(file.content)
            let skillName = meta.name ?? (file.dir.isEmpty ? name : file.dir)
            return (skillName, meta.description, installed.contains(skillName))
        }
        for extra in includedSkills() where !skills.contains(where: { $0.name == extra.name }) {
            skills.append((extra.name, extra.description, installed.contains(extra.name)))
        }
        skills.sort { localeCompare($0.name, $1.name) < 0 }
        guard !skills.isEmpty else {
            writeln("No skills found.")
            return 0
        }
        let width = skills.map(\.name.count).max() ?? 0
        var lines = skills.map { skill in
            let padding = skill.description.map { String(repeating: " ", count: width - skill.name.count) + "  \($0)" } ?? ""
            return "  \(skill.installed ? "✓" : "✗") \(skill.name)\(padding)"
        }
        let count = skills.filter(\.installed).count
        lines += ["", "\(skills.count) skill\(skills.count == 1 ? "" : "s") (\(count) installed)"]
        writeln(lines.joined(separator: "\n"))
        return 0
    }

    private func syncSkills(depth: Int, global: Bool, flags: BuiltinFlags) -> Int32 {
        let files = FileManager.default
        let temp = files.temporaryDirectory.appendingPathComponent("swiftcur-skills-\(name)-\(UUID().uuidString)").path
        defer { try? files.removeItem(atPath: temp) }
        do {
            io.stdout("Syncing...")
            var skills: [(name: String, description: String?)] = []
            for file in skillFiles(depth: depth) {
                let dir = file.dir.isEmpty ? temp : "\(temp)/\(file.dir)"
                try files.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try (file.content + "\n").write(toFile: "\(dir)/SKILL.md", atomically: true, encoding: .utf8)
                let meta = SkillFile.frontmatter(file.content)
                skills.append((meta.name ?? (file.dir.isEmpty ? name : file.dir), meta.description))
            }
            for extra in includedSkills() {
                try files.createDirectory(atPath: "\(temp)/\(extra.name)", withIntermediateDirectories: true)
                try extra.content.write(toFile: "\(temp)/\(extra.name)/SKILL.md", atomically: true, encoding: .utf8)
                if !skills.contains(where: { $0.name == extra.name }) { skills.append((extra.name, extra.description)) }
            }

            let installer = SkillInstaller(environment: io.environment)
            let result = installer.install(from: temp, global: global, cwd: cwd)
            let current = Set(result.paths.map { ($0 as NSString).lastPathComponent })
            for old in SkillMeta.read(name, io.environment)?.skills ?? [] where !current.contains(old) {
                installer.uninstall(old, global: global, cwd: cwd)
            }
            SkillMeta(hash: skillsHash(), skills: Array(current).sorted(), paths: result.paths + result.agents.map(\.path),
                      at: ISO8601DateFormatter().string(from: Date())).write(name, io.environment)

            io.stdout("\r\u{1B}[K")
            skills.sort { localeCompare($0.name, $1.name) < 0 }
            let width = skills.map(\.name.count).max() ?? 0
            var lines = skills.map { skill in
                "  ✓ \(skill.name)" + (skill.description.map { String(repeating: " ", count: width - skill.name.count) + "  \($0)" } ?? "")
            }
            lines += ["", "\(skills.count) skill\(skills.count == 1 ? "" : "s") synced"]
            if let body = cli.sync?.body { lines += ["", body] }
            if let suggestions = cli.sync?.suggestions, !suggestions.isEmpty {
                lines += ["", "Your agent can now use \(name). Try asking:"] + suggestions.map { "  \"\($0)\"" }
            }
            lines += ["", "Run `\(name) --help` to see the full command reference."]
            writeln(lines.joined(separator: "\n"))
            if flags.fullOutput || flags.formatExplicit {
                var output: JSONObject = ["skills": .array(result.paths.map(JSON.string))]
                if let body = cli.sync?.body { output["body"] = .string(body) }
                if flags.fullOutput, !result.agents.isEmpty {
                    output["agents"] = .array(result.agents.map { ["agent": .string($0.agent), "path": .string($0.path), "mode": .string($0.mode)] })
                }
                writeln(Formatter.format(.object(output), flags.formatExplicit ? flags.format : .toon))
            }
            return 0
        } catch {
            writeln(Formatter.format(["code": "SYNC_SKILLS_FAILED", "message": .string(errorMessage(error))],
                                     flags.formatExplicit ? flags.format : .toon))
            return 1
        }
    }

    // MARK: mcp

    func handleMcpCommand(_ flags: BuiltinFlags, _ filtered: [String], argv: [String]) async -> Int32? {
        guard let index = builtinIndex(filtered, "mcp") else { return nil }
        let builtin = Builtin.mcp
        let token = index + 1 < filtered.count ? filtered[index + 1] : nil
        guard let token else {
            writeln(builtinHelp(builtin))
            return 0
        }
        guard let sub = builtin.subcommand(token) else { return unknownSubcommand(builtin, token, argv: argv) }
        if flags.help {
            writeln(builtinSubcommandHelp(builtin, sub))
            return 0
        }
        let format = flags.formatExplicit ? flags.format : .toon
        if sub.name == "doctor" {
            let result = await McpServer(runtime: self).doctor()
            writeln(Formatter.format(result, format))
            return result["ok"] == .bool(true) ? 0 : 1
        }

        let rest = Array(filtered.dropFirst(index + 2))
        var command = cli.mcp?.command
        var agents = cli.mcp?.agents ?? []
        var position = 0
        while position < rest.count {
            if ["--command", "-c"].contains(rest[position]), position + 1 < rest.count {
                command = rest[position + 1]
                position += 1
            } else if rest[position] == "--agent", position + 1 < rest.count {
                agents.append(rest[position + 1])
                position += 1
            }
            position += 1
        }
        let serverName = cli.mcp?.name ?? name
        io.stdout("Registering MCP server...")
        let result = McpRegistrar(environment: io.environment).register(
            name: serverName, command: command ?? defaultMcpCommand(), agents: agents, global: !rest.contains("--no-global"), cwd: cwd
        )
        io.stdout("\r\u{1B}[K")
        guard !result.agents.isEmpty || result.errors.isEmpty else {
            writeln(Formatter.format(["code": "MCP_ADD_FAILED", "message": .string(result.errors.joined(separator: "; "))], format))
            return 1
        }
        var lines = ["✓ Registered \(serverName) as MCP server"]
        if !result.agents.isEmpty { lines.append("  Agents: \(result.agents.joined(separator: ", "))") }
        lines += ["", "Agents can now use \(serverName) tools."]
        if let suggestions = cli.sync?.suggestions, !suggestions.isEmpty {
            lines += ["", "Try asking:"] + suggestions.map { "  \"\($0)\"" }
        }
        writeln(lines.joined(separator: "\n"))
        if flags.fullOutput || flags.formatExplicit {
            writeln(Formatter.format(["name": .string(serverName), "command": .string(result.command),
                                      "agents": .array(result.agents.map(JSON.string))], format))
        }
        return 0
    }

    /// The command agents run: this binary's absolute path plus `--mcp`.
    private func defaultMcpCommand() -> String {
        let executable = io.executable ?? name
        if executable.contains("/") {
            let path = URL(fileURLWithPath: executable).standardizedFileURL.resolvingSymlinksInPath().path
            return "\(shellQuote(path)) --mcp"
        }
        return "\(name) --mcp"
    }
}

/// Matches `*` in each path segment.
func glob(_ pattern: String, in base: String) -> [String] {
    var matches = [base]
    for segment in pattern.split(separator: "/").map(String.init) {
        matches = matches.flatMap { dir -> [String] in
            guard segment.contains("*") else {
                let path = "\(dir)/\(segment)"
                return FileManager.default.fileExists(atPath: path) ? [path] : []
            }
            let regex = "^" + NSRegularExpression.escapedPattern(for: segment).replacingOccurrences(of: "\\*", with: ".*") + "$"
            return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
                .filter { $0.range(of: regex, options: .regularExpression) != nil }
                .map { "\(dir)/\($0)" }
        }
    }
    return matches
}

func shellQuote(_ text: String) -> String {
    text.range(of: #"^[A-Za-z0-9_./=:@%+-]+$"#, options: .regularExpression) != nil
        ? text : "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Splits a command line on spaces, honoring single and double quotes.
func splitCommand(_ input: String) -> [String] {
    var tokens: [String] = []
    var current = ""
    var quote: Character?
    for character in input {
        if let active = quote {
            if character == active { quote = nil } else { current.append(character) }
        } else if character == "\"" || character == "'" {
            quote = character
        } else if character == " " {
            if !current.isEmpty { tokens.append(current) }
            current = ""
        } else {
            current.append(character)
        }
    }
    if !current.isEmpty { tokens.append(current) }
    return tokens
}
