# swiftcur

Build command-line tools in Swift that work equally well for people and for AI agents.

swiftcur is a Swift port of [incur](https://github.com/wevm/incur). You define commands with typed arguments and options, and every CLI you build gets the same agent features for free: token-efficient output, a command manifest for LLMs, generated agent skills, an MCP server, shell completions, and structured errors with suggested next commands.

- **Pure Swift, no dependencies.** Only Foundation and CryptoKit.
- **One binary.** Your CLI, its MCP server, and its skill installer are the same executable.
- **Fast.** About 4 ms per command on an M-series Mac, roughly 10× faster than the same CLI on incur with Bun.
- **Output-compatible with incur.** 142 recorded cases from incur 0.7.0 (help text, errors, every output format, MCP sessions, skill files) are checked byte for byte in the test suite.

## Install

Add the package to `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/sunwrobert/swiftcur", branch: "main"),
],
targets: [
    .executableTarget(name: "my-cli", dependencies: [.product(name: "Swiftcur", package: "swiftcur")]),
]
```

Requires Swift 5.9 and macOS 13 or later.

## Quick start

```swift
import Swiftcur

let cli = CLI("greet", description: "A greeting CLI", version: "1.0.0")
    .command("hello", Command(
        description: "Say hello",
        args: ["name": .string.describe("Who to greet")],
        options: ["loud": .boolean.default(false).describe("Shout it")],
        alias: ["loud": "l"]
    ) { context in
        var message = "hello \(context.args["name"]!.stringValue!)"
        if context.options["loud"] == true { message = message.uppercased() }
        return .ok(["message": .string(message)])
    })

await cli.serve()
```

```console
$ greet hello world -l
message: HELLO WORLD

$ greet hello world --json
{
  "message": "hello world"
}

$ greet hello
Error: missing required argument <name>
See below for usage.
...
```

## Defining commands

### Arguments and options

Arguments are positional and keep their declared order. Options become `--kebab-case` flags. Option values are converted to their schema's type; positional arguments arrive as strings, so add `.coerce()` to read one as a number or boolean.

```swift
Command(
    args: [
        "source": .string.describe("File to copy"),
        "count": .int.coerce().optional(),             // "3" becomes 3
        "targets": .array(.string).optional(),           // variadic: must be last
    ],
    options: [
        "force": .boolean.default(false),                // --force, --no-force
        "retries": .int.min(0).max(5).default(3),        // --retries 2, --retries=2
        "mode": .choice("fast", "safe").optional(),      // validated, completed in the shell
        "tag": .array(.string).default([]),              // --tag a --tag b
        "verbose": Schema.count,                         // -vvv gives 3
        "legacy": .string.optional().deprecated(),       // warns when used
    ],
    alias: ["force": "f", "verbose": "v"]
) { context in ... }
```

Short flags can be stacked (`-fv`). `--` ends option parsing. Unknown flags, missing values, and invalid values are errors, with per-field details.

### Schemas

| Schema | Accepts |
|---|---|
| `.string`, `.number`, `.int`, `.boolean`, `.any` | The obvious types |
| `.array(schema)`, `.object(shape)` | Lists and nested objects |
| `.choice("a", "b")` | One of a fixed set of strings |
| `.literals("a", "b")` | A union of string literals |
| `Schema.count` | A repeatable counter flag |

Modifiers: `.optional()`, `.default(value)`, `.describe(text)`, `.min(n)`, `.max(n)`, `.deprecated()`, `.coerce()` (convert a string before validating). Every schema also produces JSON Schema, which powers `--schema`, `--llms-full`, MCP tool definitions, and skill files.

### Typed input and output

Read raw values from `context.args` and `context.options`, or decode them:

```swift
struct Input: Decodable { let name: String; let loud: Bool }
struct Reply: Encodable { let message: String }

Command(args: ["name": .string], options: ["loud": .boolean.default(false)]) { context -> Reply in
    let input = try context.args(as: Input.self, options: true)
    return Reply(message: input.loud ? input.name.uppercased() : input.name)
}
```

Return any `Encodable` value, or a `Response` for more control. Struct field order is kept in the output.

### Environment variables and globals

```swift
let cli = CLI("deploy",
    env: ["API_TOKEN": .string.describe("API token")],             // parsed for every command
    globals: ["region": .string.default("us-east").describe("Region")],
    globalAlias: ["region": "r"]
)

Command(env: ["DEPLOY_KEY": .string.optional()]) { context in
    context.env["DEPLOY_KEY"]     // command env
    context.globals["region"]     // global option, accepted anywhere in argv
    ...
}
```

Help shows which environment variables are set, with values redacted.

### Groups and nesting

Mount one CLI inside another to make command groups:

```swift
let users = CLI("users", description: "Manage users")
    .command("list", Command { _ in .ok([]) })
    .command("get", Command(args: ["id": .int.coerce()]) { context in .ok(context.args["id"]!) })

let cli = CLI("app").command(users)    // app users list, app users get 3
```

A CLI with only a `root` handler mounts as a single command. Groups can have their own root handler, middleware, and output policy.

### Results, errors, and suggested commands

```swift
return .ok(data, cta: ["users list", Cta("users get", description: "inspect one", args: [("id", true)])])

return .error(code: "NOT_FOUND", message: "No user 7", cta: ["users list"], exitCode: 4, retryable: false)

throw CommandError(code: "RATE_LIMITED", message: "Try again later", retryable: true)
```

Suggested commands ("CTAs") tell agents what to run next. They print under the result for people and are included in structured output for agents. Any other thrown error becomes `UNKNOWN`.

### Streaming

```swift
Command(description: "Tail logs") { _ in
    .stream { emitter in
        try await emitter.emit(["line": "starting"])
        try await emitter.emit(["line": "done"])
        return .ok(cta: ["status"])
    }
}
```

Chunks print as they arrive, or as JSON Lines with `--format jsonl`. `--json` collects them into one array. Over MCP, each chunk is sent as a progress notification.

### Middleware

```swift
let cli = CLI("app", env: ["API_TOKEN": .string.optional()])

cli.use { context, next in
    guard context.env["API_TOKEN"] != nil else {
        return context.error(code: "AUTH", message: "Set API_TOKEN", cta: ["login"])
    }
    context.set("user", try await fetchUser())
    try await next()
}

Command { context in .ok(["user": .string(context.vars.get("user", as: String.self) ?? "")]) }
```

Middleware runs onion-style: CLI, then group, then command middleware. `context.env` holds the CLI's declared `env` fields.

### More command options

| Option | Effect |
|---|---|
| `aliases` | Alternative command names |
| `examples`, `usage`, `hint` | Shown in help and skill files |
| `format` | Default output format for this command |
| `outputPolicy: .agentOnly` | Hide data from people in a terminal; agents still get it |
| `destructive: true` | Skill files tell agents to confirm first |
| `mcp: .hidden` or `.tool(name:description:annotations:instructions:)` | How the command appears over MCP |
| `middleware` | Middleware for just this command |

CLI-level options include `aliases` (extra binary names), `format`, `outputPolicy`, `banner`, `vars`, `config`, `sync`, `mcp`, and `update`.

## What every CLI gets

### Output formats

| Flag | Output |
|---|---|
| (default) | [TOON](https://github.com/toon-format/spec), a compact format that uses far fewer tokens than JSON |
| `--json`, `--format json` | Pretty JSON |
| `--format yaml` | YAML |
| `--format md` | Markdown tables |
| `--format jsonl` | JSON Lines, for streams |
| `--full-output` | The full envelope: `{ ok, data / error, meta: { command, duration, cta } }` |
| `--filter-output users[0,2].name,total` | Only these key paths |
| `--token-count`, `--token-limit n`, `--token-offset n` | Measure or page large outputs by estimated tokens |

People in a terminal see readable output and errors. When stdout is not a terminal, swiftcur assumes an agent and writes structured output. `context.agent` tells your command which case it is in.

### Help and discovery

| Command | What it does |
|---|---|
| `--help`, `-h` | Help for the CLI, a group, or a command |
| `--version` | Prints the version |
| `--schema` | JSON Schema for a command's args, options, env, and output |
| `--llms` | A compact Markdown table of every command, for an agent's context |
| `--llms-full` | Full Markdown docs for every command; `--format json` for a machine-readable manifest |

Mistyped commands get a "Did you mean…?" suggestion.

### Agent skills

```console
$ my-cli skills add          # write SKILL.md files and install them for detected agents
$ my-cli skills add --depth 0 --no-global
$ my-cli skills list
```

Skills are generated from your commands, one file per top-level command or group. They go to `~/.agents/skills`, which Amp, Cline, Codex, Cursor, Gemini CLI, GitHub Copilot, Kimi CLI, and OpenCode read directly. Claude Code, Windsurf, Continue, Roo, Kilo, Goose, Augment, Trae, Junie, Crush, Kiro CLI, Qwen Code, and OpenHands get symlinks. When your commands change, the CLI tells people their installed skills are out of date.

Configure with `SyncOptions`: `depth`, `include` (paths to hand-written `SKILL.md` files), `body`, and `suggestions` (example prompts). Pass `sync: nil` to turn skills off.

### MCP server

```console
$ my-cli --mcp               # serve over stdio
$ my-cli mcp add             # register with Claude Code, Cursor, Codex, Gemini CLI, Windsurf, VS Code, OpenCode, and Amp
$ my-cli mcp add --agent cursor --command "my-cli --mcp"
$ my-cli mcp doctor          # start the server in-process and list its tools
```

By default the server uses progressive discovery: four tools (`search_tools`, `get_tool_details`, `call_read_tool`, `call_write_tool`) instead of one tool per command, which keeps tool lists small. Use `McpOptions(tools: ToolFilter(discovery: .direct))` to expose every command as its own tool, and `include`/`exclude` patterns to filter them. Commands with `readOnlyHint: true` can only run through `call_read_tool`.

### Shell completions

```console
$ eval "$(my-cli completions zsh)"     # also bash, fish, nushell
```

Completions are dynamic: on every tab press the shell asks the binary, so they cover subcommands, flags, short aliases, and choice values and never go stale.

### Config file defaults

```swift
let cli = CLI("deploy", config: ConfigOptions(flag: "config", files: ["deploy.json", "~/.config/deploy/config.json"]))
```

```json
{
  "options": { "verbose": true },
  "commands": { "release": { "options": { "region": "eu-west" } } }
}
```

The first file found supplies option defaults. Precedence is argv, then config, then schema defaults. `--config <path>` picks a file and `--no-config` skips it. Pass a `loader` to read other formats, and call `cli.configSchema()` to generate a JSON Schema for editors.

### Updates

```swift
CLI("tool", version: "1.0.0", update: UpdateOptions(
    check: { _ in try await latestReleaseVersion() },
    install: { _ in try await installLatest() }
))
```

When a newer version is cached, people see an update notice; the check refreshes in the background at most once a day. `--update` runs your installer. Notices are off in CI and when `NO_UPDATE_NOTIFIER` is set.

## Testing your CLI

`cli.run(argv, io:)` runs a command in-process and returns the exit code. Pass an `IO` to capture output, fake a terminal, and set the environment:

```swift
var output = ""
let io = IO(stdout: { output += $0 }, stderr: { output += $0 }, isTTY: false,
            environment: [:], executable: "my-cli")
let code = await cli.run(["users", "list", "--json"], io: io)
```

## Differences from incur

swiftcur covers incur's features for local CLIs. It does not include incur's HTTP side (serving a CLI as an HTTP API, MCP over HTTP, mounting HTTP or OpenAPI handlers as commands, proxying remote MCP servers), file-based command routing, or its Node and npm tooling (Bun binary builds, npm-based updates, TypeScript type generation). [INVENTORY.md](INVENTORY.md) lists every incur feature and what swiftcur does with it.

A few things work differently because Swift is not TypeScript:

- Schemas are Swift values (`.string.optional()`) instead of Zod.
- `mcp add` writes agent config files directly instead of shelling out to `npx add-mcp`.
- Updates use `check`/`install` closures you provide instead of npm.
- Skill install state lives in `~/.local/share/swiftcur`; completion functions are named `_swiftcur_complete_<name>`.

## Development

```console
$ swift test                    # unit tests, plus every recorded incur case run in-process
$ scripts/compare.sh            # the same cases against the compiled demo binary, including shell-only cases
$ scripts/record-incur.sh Tests/SwiftcurTests/Fixtures/cases/cases1.txt   # re-record from real incur (needs it checked out at /tmp/incur)
```

`Examples/DemoCLI` defines the same CLI as `Tests/SwiftcurTests/Fixtures/demo.ts` in incur, so their outputs can be compared case by case.

## License

MIT. swiftcur is derived from incur, copyright weth, LLC; see [LICENSE](LICENSE).
