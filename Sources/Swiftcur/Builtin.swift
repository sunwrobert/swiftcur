/// Built-in commands every CLI gets.
struct Builtin {
    struct Subcommand {
        var name: String
        var aliases: [String] = []
        var description: String
        var options: Shape?
        var alias: [String: String] = [:]
    }

    var name: String
    var aliases: [String] = []
    var description: String
    var args: Shape?
    var subcommands: [Subcommand] = []

    static let shells = ["bash", "fish", "nushell", "zsh"]

    static let completions = Builtin(
        name: "completions", description: "Generate shell completion script",
        args: ["shell": .choice(shells).describe("Shell to generate completions for")]
    )

    static let mcp = Builtin(name: "mcp", description: "Register as MCP server", subcommands: [
        Subcommand(name: "add", description: "Register as MCP server", options: [
            "agent": .string.optional().describe("Target a specific agent (e.g. claude-code, cursor)"),
            "command": .string.optional().describe("Override the command agents will run (e.g. \"pnpm my-cli --mcp\")"),
            "noGlobal": .boolean.optional().describe("Install to project instead of globally"),
        ], alias: ["command": "c"]),
        Subcommand(name: "doctor", description: "Validate MCP server startup and tool listing"),
    ])

    static let skills = Builtin(name: "skills", aliases: ["skill"], description: "Sync skill files to agents", subcommands: [
        Subcommand(name: "add", description: "Sync skill files to agents", options: [
            "depth": .number.optional().describe("Grouping depth for skill files (default: 1)"),
            "noGlobal": .boolean.optional().describe("Install to project instead of globally"),
        ]),
        Subcommand(name: "list", aliases: ["ls"], description: "List skills"),
    ])

    static let all = [completions, mcp, skills]

    static func find(_ token: String?) -> Builtin? {
        guard let token else { return nil }
        return all.first { $0.name == token || $0.aliases.contains(token) }
    }

    func subcommand(_ token: String) -> Subcommand? {
        subcommands.first { $0.name == token || $0.aliases.contains(token) }
    }

    static func completionsHint(_ name: String) -> String {
        let rows = [
            ("bash", "eval \"$(\(name) completions bash)\"", "# add to ~/.bashrc"),
            ("fish", "\(name) completions fish | source", "# add to ~/.config/fish/config.fish"),
            ("nushell", "see `\(name) completions nushell`", "# add to config.nu"),
            ("zsh", "eval \"$(\(name) completions zsh)\"", "# add to ~/.zshrc"),
        ]
        let shellWidth = rows.map(\.0.count).max()!
        let commandWidth = rows.map(\.1.count).max()!
        return "Setup:\n" + rows.map { shell, command, comment in
            "  \(shell.padding(toLength: shellWidth, withPad: " ", startingAt: 0))  "
                + "\(command.padding(toLength: commandWidth, withPad: " ", startingAt: 0))  \(comment)"
        }.joined(separator: "\n")
    }
}
