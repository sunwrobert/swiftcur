# incur feature inventory

Every feature of [incur](https://github.com/wevm/incur) 0.7.0 (commit `323421a`, 2026-10-01), and what swiftcur does with it. Sourced from incur's README and `src/` (~10k lines excluding tests).

Goals for swiftcur: pure Swift, no dependencies, one binary, fast startup (target: under 10 ms for any command). A feature is ported when it helps a local Swift CLI used by people and agents; it is skipped when it only exists because incur runs on Node, npm, or HTTP servers.

Status key: **Port** (same behavior), **Adapt** (same goal, Swift-shaped), **Skip** (reason given).

## 1. Defining commands

| # | Feature | incur | swiftcur | Status |
|---|---|---|---|---|
| 1.1 | Single-command CLI | `Cli.create(name, { run })` | `CLI(name:run:)` | Port |
| 1.2 | Multi-command CLI | `.command(name, def)` chaining | Result-builder or chained `.command` | Port |
| 1.3 | Nested command groups | Mount a sub-CLI with `.command(cli)` | `Group(name) { … }` | Port |
| 1.4 | Mount a root CLI as one command | `.command(rootCli)` | Same | Port |
| 1.5 | Command aliases | `aliases` on built-ins and binaries | Command and binary aliases | Port |
| 1.6 | Description, hint, examples, usage patterns | Per command | Same fields | Port |
| 1.7 | Destructive flag | `destructive: true` (skills, MCP) | Same | Port |
| 1.8 | File-based commands | `.fs()` discovers files beside the entrypoint | Swift is compiled, no runtime file discovery | Skip |
| 1.9 | Mount an HTTP fetch handler as a command | `fetch: app.fetch`, curl-style flags | Not useful for local Swift CLIs | Skip (maybe later) |
| 1.10 | Generate commands from OpenAPI | `openapi: spec`, operationId or namespace modes | Large; HTTP-centric | Skip (maybe later) |
| 1.11 | Mount a remote MCP server as commands | `mcp: 'https://…'` | HTTP MCP client; HTTP-centric | Skip (maybe later) |

## 2. Schemas and parsing

incur uses Zod for every input and output. Swift has no Zod, so swiftcur has its own `Schema` values (`.string.optional()`) that validate input, produce Zod-identical error messages, and generate the same JSON Schema. Handlers can decode input into `Decodable` types and return `Encodable` values.

| # | Feature | incur | swiftcur | Status |
|---|---|---|---|---|
| 2.1 | Typed positional args | `args: z.object` | `args: Shape` of `Schema` values | Adapt |
| 2.2 | Typed options | `options: z.object` | `options: Shape` | Adapt |
| 2.3 | Typed environment variables | `env: z.object` | `env: Shape` | Adapt |
| 2.4 | Typed output | `output: z.object` | `output: Schema`; handlers return `JSON` or any `Encodable` | Adapt |
| 2.5 | Typed global options | `globals` + `globalAlias` | Same | Adapt |
| 2.6 | Defaults, optionals, enums | Zod modifiers | `.optional()`, `.default()`, `.choice()`, `.literals()`, `.min()`, `.max()`, `.coerce()` | Adapt |
| 2.7 | `--flag value`, `--flag=value` | Yes | Yes | Port |
| 2.8 | `--no-flag` negation | Booleans | Yes | Port |
| 2.9 | Short aliases, stacked (`-abc`) | `alias: { saveDev: 'D' }` | Yes | Port |
| 2.10 | Count options (`-vvv`) | Yes | Yes | Port |
| 2.11 | Array options (repeat the flag) | Yes | Yes | Port |
| 2.12 | camelCase options as kebab-case flags | `saveDev` → `--save-dev` | Yes | Port |
| 2.13 | `--` ends option parsing | Yes | Yes | Port |
| 2.14 | Unknown flags are errors | `Unknown flag: --x` | Yes | Port |
| 2.15 | Missing value errors | Yes | Yes | Port |
| 2.16 | Type coercion (numbers, booleans) from strings | Yes | Yes | Port |
| 2.17 | Validation errors with per-field details | `fieldErrors` with path, expected, received | Yes | Port |
| 2.18 | Deprecated options | `[deprecated]` in help, warning on use | Yes | Port |
| 2.19 | Type inference into handlers | Zod generics | `context.args(as:)` decodes into any `Decodable` type | Adapt |

## 3. Running commands

| # | Feature | incur | swiftcur | Status |
|---|---|---|---|---|
| 3.1 | Run context | `agent`, `args`, `options`, `env`, `globals`, `format`, `formatExplicit`, `name`, `displayName`, `var`, `ok`, `error` | Same, as a `Context` struct | Port |
| 3.2 | Agent detection | stdout is not a TTY | `isatty(1)` | Port |
| 3.3 | `ok(data, { cta })` | Success with suggested next commands | Same | Port |
| 3.4 | `error({ code, message, hint, retryable, exitCode, cta })` | Structured failures | Same | Port |
| 3.5 | Thrown errors become `UNKNOWN` | Yes | Swift `throws` → `UNKNOWN` | Port |
| 3.6 | Streaming output | Async generators; one line per chunk; JSONL chunks | `.stream { emitter in … }` | Port |
| 3.7 | Async commands | Promises | `async` | Port |
| 3.8 | Middleware | Onion-style `use(c, next)`, per-root, group, command | Same | Port |
| 3.9 | Typed middleware variables | `vars` schema, `c.set`, `c.var` | `vars` defaults, `context.set`, `context.vars.get(_:as:)` | Adapt |
| 3.10 | Output policy | `all` or `agent-only` (hide data from humans) | Same | Port |
| 3.11 | Banner | Text shown before output, for humans, agents, or both | Same | Port |
| 3.12 | Exit codes | From errors, default 1 | Same | Port |
| 3.13 | Typo suggestions | `Did you mean …?` for unknown commands | Edit distance | Port |
| 3.14 | Command-not-found CTA | Suggests `--help` | Same | Port |

## 4. Output

| # | Feature | incur | swiftcur | Status |
|---|---|---|---|---|
| 4.1 | TOON format (default) | Token-efficient, via `@toon-format/toon` | Own encoder, matching `@toon-format/toon` 2.3.1 output | Port |
| 4.2 | JSON | Yes | Own writer matching `JSON.stringify`, keeping key order | Port |
| 4.3 | YAML | Via `yaml` | Own emitter matching the `yaml` package's defaults | Port |
| 4.4 | Markdown | Tables for flat and tabular data, headings for nesting | Same | Port |
| 4.5 | JSONL | Streaming chunks | Same | Port |
| 4.6 | `--format`, `--json` | Global flags | Same | Port |
| 4.7 | Default format per CLI | `format` option | Same | Port |
| 4.8 | Output envelope | `{ ok, data/error, meta: { command, duration, cta } }` with `--full-output` | Same | Port |
| 4.9 | `--filter-output` | Dot paths, slices (`users[0,2].name`), comma lists | Same | Port |
| 4.10 | `--token-count`, `--token-limit`, `--token-offset` | Token estimate (~96%) and pagination | Own estimator (port of tokenx's heuristic) | Port |
| 4.11 | Human CTA and error rendering | Formatted blocks | Same | Port |

## 5. Help

| # | Feature | incur | swiftcur | Status |
|---|---|---|---|---|
| 5.1 | `--help` / `-h` per CLI, group, and command | Generated | Same | Port |
| 5.2 | Sections | Usage, Arguments, Options, Environment Variables, Commands, Examples, hint, Custom Global Options, Global Options, Integrations | Same | Port |
| 5.3 | `--version` | Yes | Same | Port |
| 5.4 | `--schema` | JSON Schema for args, options, env, output | Same | Port |

## 6. Agent discovery

| # | Feature | incur | swiftcur | Status |
|---|---|---|---|---|
| 6.1 | `--llms` | Compact Markdown command table | Same | Port |
| 6.2 | `--llms-full` | Full manifest with schemas | Same | Port |
| 6.3 | `skills add` | Generates `SKILL.md` files from commands and installs them for detected agents | Same | Port |
| 6.4 | Skill grouping depth | `--depth`, default 1 | Same | Port |
| 6.5 | Include hand-written skills | `include` globs | Same | Port |
| 6.6 | Skill install targets | 21 agents: Amp, Augment, Claude Code, Cline, Codex, Continue, Crush, Cursor, Gemini CLI, GitHub Copilot, Goose, Junie, Kilo, Kimi CLI, Kiro CLI, OpenCode, OpenHands, Qwen Code, Roo, Trae, Windsurf. Universal agents read `~/.agents/skills`; others get a symlink | Same table | Port |
| 6.7 | Global vs project install | `--no-global` | Same | Port |
| 6.8 | Target specific agents | `--agent` | Same | Port |
| 6.9 | Stale-skill notice | Hash of commands; warns when installed skills are out of date | Same | Port |
| 6.10 | Post-sync text and suggested prompts | `sync.body`, `sync.suggestions` | Same | Port |
| 6.11 | Disable generated skills | `sync: false` | Same | Port |
| 6.12 | `mcp add` | Registers the CLI as an MCP server, via `npx add-mcp` plus direct config writes | Writes config for Claude Code, Cursor, Codex, Gemini CLI, Windsurf, VS Code, OpenCode, and Amp directly | Adapt |
| 6.13 | `mcp doctor` | Starts the server in-process and lists its tools | Same | Port |

## 7. MCP server

| # | Feature | incur | swiftcur | Status |
|---|---|---|---|---|
| 7.1 | `--mcp` stdio server | Official TS MCP SDK | Own JSON-RPC over stdio, matching the SDK's responses | Port |
| 7.2 | Progressive discovery (default) | 4 tools: `search_tools`, `get_tool_details`, `call_read_tool`, `call_write_tool` | Same | Port |
| 7.3 | Direct discovery | Every command is a tool | Same | Port |
| 7.4 | Tool annotations | `readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`, `title` | Same | Port |
| 7.5 | Tool filtering | Include/exclude commands; hide groups with `mcp: false` | Same | Port |
| 7.6 | Server name, title, instructions | Options | Same | Port |
| 7.7 | MCP over HTTP | `/mcp` on the fetch handler, sessions | Needs an HTTP server | Skip |

## 8. Serving as an HTTP API

| # | Feature | incur | swiftcur | Status |
|---|---|---|---|---|
| 8.1 | `cli.fetch` handler | Path → command, query/body → options, JSON envelope | Needs an HTTP server | Skip |
| 8.2 | NDJSON streaming responses | Yes | — | Skip |
| 8.3 | Generated OpenAPI at `/openapi.json` | Yes | — | Skip |

## 9. Shell completions

| # | Feature | incur | swiftcur | Status |
|---|---|---|---|---|
| 9.1 | `completions <shell>` | bash, zsh, fish, nushell | Same | Port |
| 9.2 | Dynamic completions | Hook calls the binary with `COMPLETE=<shell>` on every tab | Same | Port |
| 9.3 | Completes commands, flags, aliases, enum values | Yes | Same | Port |
| 9.4 | Completions for binary aliases | Yes | Same | Port |

## 10. Config file defaults

| # | Feature | incur | swiftcur | Status |
|---|---|---|---|---|
| 10.1 | Option defaults from JSON | `config.files`, first match wins, `~` expansion | Same | Port |
| 10.2 | `--config <path>`, `--no-config` | Configurable flag name | Same | Port |
| 10.3 | Precedence | argv > config > schema defaults | Same | Port |
| 10.4 | Custom loader | Non-JSON formats | Closure | Port |
| 10.5 | Config JSON Schema generation | `incur gen` | `cli.configSchema()` | Adapt |

## 11. Distribution and updates

| # | Feature | incur | swiftcur | Status |
|---|---|---|---|---|
| 11.1 | Standalone binaries | `incur build` with Bun, cross-platform | `swift build` already makes one | Skip |
| 11.2 | GitHub release action and install scripts | Yes | Out of scope for a library | Skip (maybe later) |
| 11.3 | Update notices and `--update` | npm/pnpm/Bun or GitHub binaries | Daily background check and `--update`, using `check`/`install` closures you provide | Adapt |

## 12. Build-time tooling

| # | Feature | incur | swiftcur | Status |
|---|---|---|---|---|
| 12.1 | Typegen for CTA autocomplete | `.d.ts` declaration merging | Swift checks this at compile time already | Skip |
| 12.2 | Skillgen | Writes skill files at build time | Covered by `skills add` | Skip |

## Totals

| Status | Count |
|---|---|
| Port | 73 |
| Adapt | 11 |
| Skip | 12 |
| **Total** | **96** |

The skipped features are the HTTP side (fetch mounting, OpenAPI, remote MCP, HTTP serving), Node packaging (Bun builds, release scripts), file-based routing, and TypeScript typegen. Everything an agent touches when it runs a local CLI is implemented.

## Status

Every Port and Adapt row is implemented. Output parity is checked against 142 cases recorded from incur 0.7.0 (`Tests/SwiftcurTests/Fixtures`), run in-process by `swift test` and against the compiled binary by `scripts/compare.sh`.
