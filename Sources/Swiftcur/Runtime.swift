import Foundation

/// Flags every CLI understands, pulled out of argv before command resolution.
struct BuiltinFlags {
    var fullOutput = false
    var llms = false
    var llmsFull = false
    var mcp = false
    var help = false
    var update = false
    var updateCheck = false
    var version = false
    var schema = false
    var format: Format = .toon
    var formatExplicit = false
    var configPath: String?
    var configDisabled = false
    var filterOutput: String?
    var tokenLimit: Int?
    var tokenOffset: Int?
    var tokenCount = false
    var rest: [String] = []

    static let updateCheckFlag = "--swiftcur-update-check"

    init(_ argv: [String], configFlag: String?) throws {
        var index = 0
        func next() -> String? { index + 1 < argv.count ? argv[index + 1] : nil }
        while index < argv.count {
            let token = argv[index]
            switch token {
            case "--full-output": fullOutput = true
            case "--llms": llms = true
            case "--llms-full": llmsFull = true
            case "--mcp": mcp = true
            case "--help", "-h": help = true
            case "--update": update = true
            case Self.updateCheckFlag: updateCheck = true
            case "--version" where next() == nil || next()!.hasPrefix("-"): version = true
            case "--schema": schema = true
            case "--json":
                format = .json
                formatExplicit = true
            case "--format" where next() != nil:
                guard let value = Format(rawValue: next()!) else {
                    throw ParseError("Invalid format: \"\(next()!)\". Expected one of: toon, json, yaml, md, jsonl")
                }
                format = value
                formatExplicit = true
                index += 1
            case "--filter-output" where next() != nil:
                filterOutput = next()
                index += 1
            case "--token-limit" where next() != nil:
                tokenLimit = try Self.number(token, next()!)
                index += 1
            case "--token-offset" where next() != nil:
                tokenOffset = try Self.number(token, next()!)
                index += 1
            case "--token-count": tokenCount = true
            default:
                if let flag = configFlag, token == "--\(flag)" {
                    guard let value = next() else { throw ParseError("Missing value for flag: --\(flag)") }
                    configPath = value
                    configDisabled = false
                    index += 1
                } else if let flag = configFlag, token.hasPrefix("--\(flag)=") {
                    let value = String(token.dropFirst(flag.count + 3))
                    guard !value.isEmpty else { throw ParseError("Missing value for flag: --\(flag)") }
                    configPath = value
                    configDisabled = false
                } else if let flag = configFlag, token == "--no-\(flag)" {
                    configPath = nil
                    configDisabled = true
                } else {
                    rest.append(token)
                }
            }
            index += 1
        }
    }

    private static func number(_ flag: String, _ value: String) throws -> Int {
        let number = jsNumber(value)
        guard number.isFinite, !value.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ParseError("Invalid value for \(flag): \"\(value)\"")
        }
        return Int(number)
    }
}

/// A resolved command or group from argv.
enum Resolution {
    case command(Command, path: String, rest: [String], middlewares: [Middleware], outputPolicy: OutputPolicy?, commands: Commands?)
    case help(path: String, description: String?, commands: Commands)
    case notFound(token: String, path: String, commands: Commands)
}

/// The success or failure envelope written for a command.
struct Output {
    var ok: Bool
    var data: JSON?
    var error: ErrorInfo?
    var meta: JSONObject

    var json: JSON {
        var object: JSONObject = ["ok": .bool(ok)]
        if ok { object["data"] = data ?? .null } else { object["error"] = error?.json ?? .null }
        object["meta"] = .object(meta)
        return .object(object)
    }
}

/// One `serve()` invocation.
final class Runtime {
    let cli: CLI
    let io: IO
    var name: String { cli.name }
    var human: Bool
    let start = Date()

    init(cli: CLI, io: IO) {
        self.cli = cli
        self.io = io
        human = io.isTTY
    }

    var displayName: String {
        guard let executable = io.executable else { return name }
        let base = (executable as NSString).lastPathComponent
        return base == name || cli.aliases.contains(base) ? base : name
    }

    var skillsEnabled: Bool { cli.sync != nil }
    var builtins: [Builtin] { skillsEnabled ? Builtin.all : Builtin.all.filter { $0.name != "skills" } }
    var globalsHelp: Help.Globals? { cli.globals.map { Help.Globals(shape: $0, alias: cli.globalAlias) } }
    var duration: String { "\(Int((Date().timeIntervalSince(start) * 1000).rounded()))ms" }

    func writeln(_ text: String) {
        io.stdout(text.hasSuffix("\n") ? text : text + "\n")
    }

    func fail(code: String, message: String) -> Int32 {
        if human {
            writeln(HumanError.format(code: code, message: message))
        } else {
            writeln(Formatter.format(["code": .string(code), "message": .string(message)], .toon))
        }
        return 1
    }

    // MARK: Serve

    func serve(_ argv: [String]) async -> Int32 {
        let flags: BuiltinFlags
        do {
            flags = try BuiltinFlags(argv, configFlag: cli.config?.flag)
        } catch {
            return fail(code: "UNKNOWN", message: errorMessage(error))
        }
        human = io.isTTY && !flags.formatExplicit

        var filtered = flags.rest
        if let globals = cli.globals {
            do {
                filtered = try Parser.parseGlobals(flags.rest, schema: globals, alias: cli.globalAlias, validate: false).rest
            } catch {
                return fail(code: "UNKNOWN", message: errorMessage(error))
            }
        }

        if flags.updateCheck {
            await Updater(cli: cli, io: io).refresh()
            return 0
        }
        if flags.update, !flags.help { return await runUpdate(flags) }
        if flags.mcp { return await McpServer(runtime: self).serveStdio() }
        if let shell = io.environment["COMPLETE"] {
            return Completions.handle(runtime: self, shell: shell, argv: argv)
        }

        let skillsNotice = flags.llms || flags.llmsFull || flags.schema || flags.help || flags.version
            ? nil : staleSkillsNotice(filtered)

        if flags.llms || flags.llmsFull { return writeManifest(flags, filtered) }
        if let code = handleCompletionsCommand(flags, filtered) { return code }
        if let code = await handleSkillsCommand(flags, filtered, argv: argv) { return code }
        if let code = await handleMcpCommand(flags, filtered, argv: argv) { return code }

        if flags.version, !flags.help, let version = cli.version {
            writeln(version)
            return 0
        }

        if filtered.isEmpty {
            if let root = cli.root, human, let args = root.args, args.fields.contains(where: { $0.schema.isRequired }) {
                await writeBanner(flags)
                writeln(Help.formatCommand(name, commandHelp(root, name: name, isRoot: true, subcommands: helpItems(cli.commands))))
                return 0
            }
            if cli.root == nil {
                await writeBanner(flags)
                writeln(Help.formatRoot(name, rootHelp(name: name, commands: cli.commands, description: cli.description, isRoot: true)))
                return 0
            }
        }

        let resolved: Resolution = filtered.isEmpty
            ? .command(cli.root!, path: name, rest: [], middlewares: [], outputPolicy: nil, commands: nil)
            : resolve(filtered)

        if flags.help { return writeHelp(resolved) }
        if flags.schema { return writeSchema(resolved, flags) }
        if case .help(let path, let description, let commands) = resolved {
            writeln(Help.formatRoot("\(name) \(path)", rootHelp(name: "\(name) \(path)", commands: commands, description: description, isRoot: false)))
            return 0
        }

        let updateNotice = human ? Updater(cli: cli, io: io).notice(displayName: displayName) : nil
        let notice = FormattedCtaBlock.merge(skillsNotice, updateNotice)
        let format = flags.formatExplicit ? flags.format : (resolvedFormat(resolved) ?? cli.format ?? .toon)

        var effective = resolved
        if case .notFound(let token, let path, let commands) = resolved, path.isEmpty, let root = cli.root,
           suggest(token, commands.names + builtins.map(\.name)) == nil {
            effective = .command(root, path: name, rest: filtered, middlewares: [], outputPolicy: nil, commands: nil)
        }

        let writer = OutputWriter(runtime: self, flags: flags, format: format, notice: notice,
                                  outputPolicy: outputPolicy(effective))

        if case .notFound(let token, let path, let commands) = effective {
            return writeNotFound(token: token, path: path, commands: commands, argv: argv, flags: flags, notice: notice, writer: writer)
        }
        guard case .command(let command, let path, let rest, let middlewares, _, _) = effective else { return 0 }

        var globals = JSONObject()
        if let shape = cli.globals {
            do {
                globals = try Parser.parseGlobals(flags.rest, schema: shape, alias: cli.globalAlias, validate: true).parsed
            } catch {
                return fail(code: "UNKNOWN", message: errorMessage(error))
            }
        }

        if human { warnDeprecated(rest, command) }

        var defaults: JSONObject?
        if cli.config != nil {
            do {
                defaults = try await ConfigLoader(cli: cli, io: io).defaults(for: path, flags: flags)
            } catch {
                let (info, exitCode) = ErrorInfo.from(error)
                writer.write(Output(ok: false, error: info, meta: ["command": .string(path), "duration": .string(duration)]))
                return exitCode ?? 1
            }
        }

        let result = await Executor.execute(command, .init(
            agent: !human, argv: rest, defaults: defaults, displayName: displayName, cliEnv: cli.env,
            environment: io.environment, format: format, formatExplicit: flags.formatExplicit, globals: globals,
            input: nil, middlewares: cli.middlewares + middlewares + command.middleware, name: name, path: path,
            vars: cli.vars, version: cli.version
        ))
        return await writer.writeResult(result, command: command, path: path)
    }

    // MARK: Resolution

    func resolve(_ tokens: [String]) -> Resolution {
        guard let first = tokens.first, var entry = cli.commands.resolved(first) else {
            return .notFound(token: tokens.first ?? "(none)", path: "", commands: cli.commands)
        }
        var path = [first]
        var remaining = Array(tokens.dropFirst())
        var inherited: OutputPolicy?
        var middlewares: [Middleware] = []

        while case .group(let group) = entry {
            if let policy = group.outputPolicy { inherited = policy }
            middlewares += group.middlewares
            guard let next = remaining.first else {
                if let root = group.root {
                    return .command(root, path: path.joined(separator: " "), rest: remaining, middlewares: middlewares,
                                    outputPolicy: root.outputPolicy ?? inherited, commands: group.commands)
                }
                return .help(path: path.joined(separator: " "), description: group.description, commands: group.commands)
            }
            guard let child = group.commands.resolved(next) else {
                if let root = group.root, suggest(next, group.commands.names) == nil {
                    return .command(root, path: path.joined(separator: " "), rest: remaining, middlewares: middlewares,
                                    outputPolicy: root.outputPolicy ?? inherited, commands: group.commands)
                }
                return .notFound(token: next, path: path.joined(separator: " "), commands: group.commands)
            }
            path.append(next)
            remaining.removeFirst()
            entry = child
        }
        guard case .command(let command) = entry else {
            return .notFound(token: first, path: "", commands: cli.commands)
        }
        return .command(command, path: path.joined(separator: " "), rest: remaining, middlewares: middlewares,
                        outputPolicy: command.outputPolicy ?? inherited, commands: nil)
    }

    private func resolvedFormat(_ resolution: Resolution) -> Format? {
        if case .command(let command, _, _, _, _, _) = resolution { return command.format }
        return nil
    }

    private func outputPolicy(_ resolution: Resolution) -> OutputPolicy {
        if case .command(_, _, _, _, let policy, _) = resolution, let policy { return policy }
        return cli.outputPolicy ?? .all
    }

    // MARK: Help

    func helpItems(_ commands: Commands) -> [Help.Item] {
        commands.canonical.map { name, entry in
            switch entry {
            case .command(let command): return Help.Item(name: name, description: command.description)
            case .group(let group): return Help.Item(name: name, description: group.description)
            case .alias: return Help.Item(name: name)
            }
        }.sorted { localeCompare($0.name, $1.name) < 0 }
    }

    func rootHelp(name helpName: String, commands: Commands, description: String?, isRoot: Bool) -> Help.RootOptions {
        Help.RootOptions(aliases: isRoot ? cli.aliases : [], configFlag: cli.config?.flag, commands: helpItems(commands),
                         description: description, globals: globalsHelp, hideSkills: !skillsEnabled, root: isRoot,
                         version: isRoot ? cli.version : nil)
    }

    func commandHelp(_ command: Command, name commandName: String, isRoot: Bool, subcommands: [Help.Item] = []) -> Help.CommandOptions {
        Help.CommandOptions(
            alias: command.alias, aliases: isRoot ? cli.aliases : command.aliases, args: command.args,
            configFlag: cli.config?.flag, commands: subcommands,
            description: isRoot ? (command.description ?? cli.description) : command.description, env: command.env,
            environment: io.environment, globals: globalsHelp,
            examples: command.examples.map { ($0.suffix, $0.description) }, hint: command.hint, hideSkills: !skillsEnabled,
            options: command.options, root: isRoot, usage: command.usage, version: isRoot ? cli.version : nil
        )
    }

    private func writeHelp(_ resolved: Resolution) -> Int32 {
        switch resolved {
        case .help(let path, let description, let commands):
            writeln(Help.formatRoot("\(name) \(path)", rootHelp(name: "\(name) \(path)", commands: commands, description: description, isRoot: false)))
        case .notFound:
            if let root = cli.root, !cli.commands.isEmpty {
                writeln(Help.formatCommand(name, commandHelp(root, name: name, isRoot: true, subcommands: helpItems(cli.commands))))
            } else {
                writeln(Help.formatRoot(name, rootHelp(name: name, commands: cli.commands, description: cli.description, isRoot: true)))
            }
        case .command(let command, let path, _, _, _, let groupCommands):
            let isRoot = path == name
            var subcommands: [Help.Item] = []
            if let groupCommands, !groupCommands.isEmpty {
                subcommands = helpItems(groupCommands)
            } else if isRoot, !cli.commands.isEmpty {
                subcommands = helpItems(cli.commands)
            }
            writeln(Help.formatCommand(isRoot ? name : "\(name) \(path)",
                                       commandHelp(command, name: path, isRoot: isRoot, subcommands: subcommands)))
        }
        return 0
    }

    private func writeSchema(_ resolved: Resolution, _ flags: BuiltinFlags) -> Int32 {
        switch resolved {
        case .help(let path, let description, let commands):
            var options = rootHelp(name: "\(name) \(path)", commands: commands, description: description, isRoot: false)
            options.hideSkills = false
            writeln(Help.formatRoot("\(name) \(path)", options))
            return 0
        case .notFound(let token, let path, let commands):
            let parent = path.isEmpty ? name : "\(name) \(path)"
            let didYouMean = suggest(token, commands.names).map { " Did you mean '\($0)'?" } ?? ""
            writeln("Error: '\(token)' is not a command for '\(parent)'.\(didYouMean)")
            return 1
        case .command(let command, _, _, _, _, _):
            var result = JSONObject()
            if let args = command.args { result["args"] = .object(Schema.objectSchema(args)) }
            if let env = command.env { result["env"] = .object(Schema.objectSchema(env)) }
            if let options = command.options { result["options"] = .object(Schema.objectSchema(options)) }
            if let output = command.output { result["output"] = output.jsonSchema }
            if let globals = cli.globals { result["globals"] = .object(Schema.objectSchema(globals)) }
            writeln(Formatter.format(.object(result), flags.formatExplicit ? flags.format : .toon))
            return 0
        }
    }

    private func writeNotFound(token: String, path: String, commands: Commands, argv: [String], flags: BuiltinFlags,
                               notice: FormattedCtaBlock?, writer: OutputWriter) -> Int32 {
        let parent = path.isEmpty ? name : "\(name) \(path)"
        var candidates = commands.names
        if path.isEmpty { candidates += builtins.map(\.name) }
        let suggestion = suggest(token, candidates)
        let message = "'\(token)' is not a command for '\(parent)'." + (suggestion.map { " Did you mean '\($0)'?" } ?? "")
        let cta = notFoundCta(suggestion: suggestion, token: token, argv: argv, helpCommand: "\(parent) --help")
        if human, !flags.fullOutput {
            writeln(HumanError.format(code: "COMMAND_NOT_FOUND", message: message))
            writeln((FormattedCtaBlock.merge(cta, notice) ?? cta).human)
            return 1
        }
        writer.write(Output(ok: false, error: ErrorInfo(code: "COMMAND_NOT_FOUND", message: message),
                            meta: ["command": .string(token), "cta": cta.json, "duration": .string(duration)]))
        return 1
    }

    func notFoundCta(suggestion: String?, token: String, argv: [String], helpCommand: String) -> FormattedCtaBlock {
        var commands: [FormattedCta] = []
        if let suggestion {
            commands.append(FormattedCta(command: "\(name) " + argv.map { $0 == token ? suggestion : $0 }.joined(separator: " ")))
        }
        commands.append(FormattedCta(command: helpCommand, description: "see all available commands"))
        return FormattedCtaBlock(description: commands.count == 1 ? "Suggested command:" : "Suggested commands:", commands: commands)
    }

    private func writeBanner(_ flags: BuiltinFlags) async {
        guard let banner = cli.banner, !flags.help else { return }
        switch banner.mode {
        case .human where !human, .agent where human: return
        default: break
        }
        if let text = await banner.render(), !text.isEmpty { writeln(text) }
    }

    private func warnDeprecated(_ argv: [String], _ command: Command) {
        guard let options = command.options else { return }
        var flags = Set<String>()
        var shorts: [String: String] = [:]
        for field in options.fields where field.schema.isDeprecated {
            let kebab = toKebab(field.name)
            flags.insert(kebab)
            if let short = command.alias[field.name] { shorts[short] = kebab }
        }
        guard !flags.isEmpty else { return }
        for token in argv {
            if token.hasPrefix("--") {
                let stripped = String(token.split(separator: "=", maxSplits: 1).first?.dropFirst(2) ?? "")
                let flag = !flags.contains(stripped) && stripped.hasPrefix("no-") ? String(stripped.dropFirst(3)) : stripped
                if flags.contains(flag) { io.stderr("Warning: --\(flag) is deprecated\n") }
            } else if token.hasPrefix("-"), token.count >= 2 {
                for character in token.dropFirst() {
                    if let flag = shorts[String(character)] { io.stderr("Warning: --\(flag) is deprecated\n") }
                }
            }
        }
    }

    // MARK: Update

    private func runUpdate(_ flags: BuiltinFlags) async -> Int32 {
        do {
            let result = try await Updater(cli: cli, io: io).install()
            if human {
                writeln("✓ Updated \(result)")
            } else {
                writeln(Formatter.format(["name": .string(result)], flags.format))
            }
            return 0
        } catch {
            let output: JSON = ["code": "UPDATE_FAILED", "message": .string(errorMessage(error))]
            if human {
                writeln(HumanError.format(code: "UPDATE_FAILED", message: errorMessage(error)))
            } else {
                writeln(Formatter.format(output, flags.format))
            }
            return 1
        }
    }
}
