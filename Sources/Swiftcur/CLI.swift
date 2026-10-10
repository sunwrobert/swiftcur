import Foundation

/// Where generated `config` defaults come from.
public struct ConfigOptions: @unchecked Sendable {
    /// Global flag for the config path, e.g. `config` gives `--config <path>` and `--no-config`. `nil` means auto-load only.
    public var flag: String?
    /// Search paths; the first that exists wins. `~` expands to the home directory. Defaults to `<name>.json`.
    public var files: [String]?
    /// Custom loader for non-JSON formats. Receives the resolved path, or `nil` when no file was found.
    public var loader: ((String?) async throws -> JSONObject?)?

    public init(flag: String? = nil, files: [String]? = nil, loader: ((String?) async throws -> JSONObject?)? = nil) {
        self.flag = flag
        self.files = files
        self.loader = loader
    }
}

/// Text shown before root help or command output.
public struct Banner: @unchecked Sendable {
    public enum Mode: Sendable { case all, human, agent }
    public var mode: Mode
    public var render: () async -> String?

    public init(mode: Mode = .all, render: @escaping () async -> String?) {
        self.mode = mode
        self.render = render
    }
}

/// Options for `skills add`.
public struct SyncOptions: Sendable {
    /// Text printed after the synced skills, before the suggestions.
    public var body: String?
    /// Directory for resolving `include` patterns. Defaults to the current directory.
    public var cwd: String?
    /// Grouping depth for skill files. Defaults to 1.
    public var depth: Int?
    /// Directories containing hand-written `SKILL.md` files. `_root` means `./SKILL.md`. `*` matches any characters.
    public var include: [String]?
    /// Example prompts shown after syncing.
    public var suggestions: [String]?

    public init(body: String? = nil, cwd: String? = nil, depth: Int? = nil, include: [String]? = nil, suggestions: [String]? = nil) {
        self.body = body
        self.cwd = cwd
        self.depth = depth
        self.include = include
        self.suggestions = suggestions
    }
}

/// Which commands an MCP client sees.
public struct ToolFilter: Sendable {
    public enum Discovery: String, Sendable { case direct, progressive }
    /// `progressive` (default) exposes search/inspect/call tools; `direct` exposes every command.
    public var discovery: Discovery
    /// Tool name patterns to expose. `*` matches any characters.
    public var include: [String]?
    /// Tool name patterns to hide. Excludes win.
    public var exclude: [String]?

    public init(discovery: Discovery = .progressive, include: [String]? = nil, exclude: [String]? = nil) {
        self.discovery = discovery
        self.include = include
        self.exclude = exclude
    }
}

/// MCP server settings.
public struct McpOptions: Sendable {
    /// Agents to register with by default, e.g. `["claude-code", "cursor"]`.
    public var agents: [String]?
    /// Command agents run to start the server. Detected when omitted.
    public var command: String?
    public var instructions: String?
    /// Server and registration name. Defaults to the CLI name.
    public var name: String?
    public var title: String?
    public var tools: ToolFilter?

    public init(agents: [String]? = nil, command: String? = nil, instructions: String? = nil, name: String? = nil,
                title: String? = nil, tools: ToolFilter? = nil) {
        self.agents = agents
        self.command = command
        self.instructions = instructions
        self.name = name
        self.title = title
        self.tools = tools
    }
}

/// Update checks and installs for `--update`.
public struct UpdateOptions: @unchecked Sendable {
    public struct CheckContext: Sendable {
        public let name: String
        public let current: String?
    }

    public struct InstallContext: Sendable {
        public let name: String
        public let current: String?
        public let latest: String?
    }

    /// Returns the latest available version, or `nil` when unknown.
    public var check: ((CheckContext) async throws -> String?)?
    /// Installs the latest version.
    public var install: ((InstallContext) async throws -> Void)?
    /// Minimum seconds between background checks. Defaults to one day.
    public var interval: TimeInterval

    public init(check: ((CheckContext) async throws -> String?)? = nil, install: ((InstallContext) async throws -> Void)? = nil,
                interval: TimeInterval = 86_400) {
        self.check = check
        self.install = install
        self.interval = interval
    }
}

/// An entry in a command map.
enum Entry {
    case command(Command)
    case group(Group)
    case alias(String)
}

/// A named group of commands, optionally with its own handler.
final class Group {
    var description: String?
    var commands: Commands
    var root: Command?
    var middlewares: [Middleware]
    var outputPolicy: OutputPolicy?
    var mcpHidden: Bool

    init(description: String?, commands: Commands, root: Command?, middlewares: [Middleware], outputPolicy: OutputPolicy?,
         mcpHidden: Bool = false) {
        self.description = description
        self.commands = commands
        self.root = root
        self.middlewares = middlewares
        self.outputPolicy = outputPolicy
        self.mcpHidden = mcpHidden
    }
}

/// Command entries in registration order.
struct Commands {
    private(set) var names: [String] = []
    private var entries: [String: Entry] = [:]

    var isEmpty: Bool { names.isEmpty }
    var count: Int { names.count }

    subscript(name: String) -> Entry? { entries[name] }

    mutating func set(_ name: String, _ entry: Entry) {
        if entries.updateValue(entry, forKey: name) == nil { names.append(name) }
    }

    /// Entries with aliases resolved.
    func resolved(_ name: String) -> Entry? {
        guard let entry = entries[name] else { return nil }
        if case .alias(let target) = entry { return entries[target] }
        return entry
    }

    /// Non-alias entries in order.
    var canonical: [(name: String, entry: Entry)] {
        names.compactMap { name in
            guard let entry = entries[name] else { return nil }
            if case .alias = entry { return nil }
            return (name, entry)
        }
    }
}

/// An agent-friendly command-line app. Build it with `command`, then call `serve()`.
public final class CLI: @unchecked Sendable {
    public let name: String
    public var description: String?
    public var version: String?
    /// Alternative binary names. Shell completions are registered for each.
    public var aliases: [String]
    public var env: Shape?
    public var globals: Shape?
    public var globalAlias: [String: String]
    public var config: ConfigOptions?
    public var format: Format?
    public var outputPolicy: OutputPolicy?
    public var banner: Banner?
    /// `nil` disables generated skills and the `skills` commands.
    public var sync: SyncOptions?
    public var mcp: McpOptions?
    /// `nil` hides update notices; `--update` then reports that no updater is configured.
    public var update: UpdateOptions?
    public var vars: JSONObject
    /// Handler run when no subcommand is given.
    public var root: Command?

    var commands = Commands()
    var middlewares: [Middleware] = []

    public init(
        _ name: String, description: String? = nil, version: String? = nil, aliases: [String] = [], env: Shape? = nil,
        globals: Shape? = nil, globalAlias: [String: String] = [:], config: ConfigOptions? = nil, format: Format? = nil,
        outputPolicy: OutputPolicy? = nil, banner: Banner? = nil, sync: SyncOptions? = SyncOptions(), mcp: McpOptions? = nil,
        update: UpdateOptions? = nil, vars: JSONObject = [:], root: Command? = nil
    ) {
        self.name = name
        self.description = description
        self.version = version
        self.aliases = aliases
        self.env = env
        self.globals = globals
        self.globalAlias = globalAlias
        self.config = config
        self.format = format
        self.outputPolicy = outputPolicy
        self.banner = banner
        self.sync = sync
        self.mcp = mcp
        self.update = update
        self.vars = vars
        self.root = root
        if let globals { Self.checkGlobals(globals, globalAlias, config) }
    }

    /// Registers a command.
    @discardableResult
    public func command(_ name: String, _ command: Command) -> CLI {
        if let globals { Self.checkConflicts(name, command, globals, globalAlias) }
        commands.set(name, .command(command))
        for alias in command.aliases { commands.set(alias, .alias(name)) }
        return self
    }

    /// Mounts another CLI as a command group (or as a single command if it only has a root handler).
    @discardableResult
    public func command(_ cli: CLI) -> CLI {
        if cli.commands.isEmpty, let root = cli.root {
            var mounted = root
            if mounted.description == nil { mounted.description = cli.description }
            mounted.middleware = cli.middlewares + mounted.middleware
            return command(cli.name, mounted)
        }
        let group = Group(description: cli.description, commands: cli.commands, root: cli.root,
                          middlewares: cli.middlewares, outputPolicy: cli.outputPolicy)
        if let globals {
            for (name, entry) in cli.commands.canonical { Self.checkEntry("\(cli.name) \(name)", entry, globals, globalAlias) }
        }
        commands.set(cli.name, .group(group))
        for alias in cli.aliases { commands.set(alias, .alias(cli.name)) }
        return self
    }

    /// Adds middleware that wraps every command.
    @discardableResult
    public func use(_ middleware: @escaping Middleware) -> CLI {
        middlewares.append(middleware)
        return self
    }

    /// Parses `CommandLine.arguments`, runs the command, and exits.
    public func serve() async -> Never {
        let code = await run(Array(CommandLine.arguments.dropFirst()))
        exit(code)
    }

    /// Runs with explicit argv and I/O. Returns the exit code.
    public func run(_ argv: [String], io: IO = .standard) async -> Int32 {
        await Runtime(cli: self, io: io).serve(argv)
    }

    // MARK: Definition checks (programmer errors, like incur's thrown definition errors)

    private static let reservedFlags = [
        "verbose", "format", "json", "llms", "llmsFull", "mcp", "help", "update", "version", "schema",
        "filterOutput", "tokenLimit", "tokenOffset", "tokenCount", "fullOutput",
    ]

    private static func checkGlobals(_ globals: Shape, _ alias: [String: String], _ config: ConfigOptions?) {
        var reserved = reservedFlags
        if let flag = config?.flag { reserved += [flag, "no" + flag.prefix(1).uppercased() + flag.dropFirst()] }
        for name in globals.names where reserved.contains(name) {
            preconditionFailure("Global option '\(name)' conflicts with a built-in flag. Choose a different name.")
        }
        for (name, short) in alias where short == "h" {
            preconditionFailure("Global alias '-\(short)' for '\(name)' conflicts with a built-in short flag. Choose a different alias.")
        }
    }

    private static func checkEntry(_ path: String, _ entry: Entry, _ globals: Shape, _ alias: [String: String]) {
        switch entry {
        case .alias: return
        case .command(let command): checkConflicts(path, command, globals, alias)
        case .group(let group):
            if let root = group.root { checkConflicts(path, root, globals, alias) }
            for (name, child) in group.commands.canonical { checkEntry("\(path) \(name)", child, globals, alias) }
        }
    }

    private static func checkConflicts(_ path: String, _ command: Command, _ globals: Shape, _ alias: [String: String]) {
        for name in command.options?.names ?? [] where globals[name] != nil {
            preconditionFailure("Command '\(path)' option '\(name)' conflicts with a global option. Choose a different name.")
        }
        let globalShorts = Set(alias.values)
        for (name, short) in command.alias where globalShorts.contains(short) {
            preconditionFailure("Command '\(path)' alias '-\(short)' for '\(name)' conflicts with a global alias. Choose a different alias.")
        }
    }
}

/// Where a CLI reads input and writes output. Swap it in tests.
public struct IO: @unchecked Sendable {
    public var stdout: (String) -> Void
    public var stderr: (String) -> Void
    public var isTTY: Bool
    public var environment: [String: String]
    /// `argv[0]`, used to detect which alias the user typed.
    public var executable: String?
    public var stdin: () -> String?

    public init(stdout: @escaping (String) -> Void, stderr: @escaping (String) -> Void, isTTY: Bool,
                environment: [String: String], executable: String?, stdin: @escaping () -> String? = { readLine() }) {
        self.stdout = stdout
        self.stderr = stderr
        self.isTTY = isTTY
        self.environment = environment
        self.executable = executable
        self.stdin = stdin
    }

    public static var standard: IO {
        IO(
            stdout: { text in FileHandle.standardOutput.write(Data(text.utf8)) },
            stderr: { text in FileHandle.standardError.write(Data(text.utf8)) },
            isTTY: isatty(STDOUT_FILENO) == 1,
            environment: ProcessInfo.processInfo.environment,
            executable: CommandLine.arguments.first
        )
    }
}
