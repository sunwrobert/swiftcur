import Foundation

/// A command exposed as an MCP tool.
struct ToolEntry {
    var name: String
    var description: String?
    var inputSchema: JSON
    var outputSchema: JSON?
    var annotations: ToolAnnotations?
    var instructions: String?
    var command: Command
    var path: String
    var middlewares: [Middleware]

    var summary: JSON {
        var object: JSONObject = ["name": .string(name)]
        if let description { object["description"] = .string(description) }
        if let annotations { object["annotations"] = annotations.json }
        return .object(object)
    }
}

/// MCP server over stdio (newline-delimited JSON-RPC 2.0).
final class McpServer {
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05", "2024-10-07"]

    let runtime: Runtime
    var cli: CLI { runtime.cli }
    private var tools: [ToolEntry] = []
    private var discovery: ToolFilter.Discovery
    private let writeLock = NSLock()

    init(runtime: Runtime, discovery: ToolFilter.Discovery? = nil) {
        self.runtime = runtime
        self.discovery = discovery ?? runtime.cli.mcp?.tools?.discovery ?? .progressive
    }

    var serverName: String { cli.mcp?.name ?? cli.name }

    // MARK: Transport

    func serveStdio() async -> Int32 {
        do {
            tools = try collectTools()
        } catch {
            runtime.io.stderr("\(errorMessage(error))\n")
            return 1
        }
        while let line = runtime.io.stdin() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let response = await handle(trimmed) { send(response) }
        }
        return 0
    }

    private func send(_ message: JSON) {
        writeLock.lock()
        defer { writeLock.unlock() }
        runtime.io.stdout(JSONWriter.stringify(message) + "\n")
    }

    /// Handles one JSON-RPC message and returns the response, if any.
    func handle(_ text: String) async -> JSON? {
        guard let message = try? JSONParser.parse(text), let object = message.objectValue else {
            return ["jsonrpc": "2.0", "id": nil, "error": ["code": -32700, "message": "Parse error"]]
        }
        let id = object["id"]
        guard let method = object["method"]?.stringValue else { return nil }
        let params = object["params"]?.objectValue ?? JSONObject()
        guard let id else { return nil } // notification
        do {
            let result = try await dispatch(method, params)
            return ["jsonrpc": "2.0", "id": id, "result": result]
        } catch let error as RpcError {
            return ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(error.code)), "message": .string(error.message)]]
        } catch {
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": .string(errorMessage(error))]]
        }
    }

    private struct RpcError: Error {
        let code: Int
        let message: String
    }

    private func dispatch(_ method: String, _ params: JSONObject) async throws -> JSON {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue ?? ""
            var info: JSONObject = ["name": .string(serverName), "version": .string(cli.version ?? "0.0.0")]
            if let title = cli.mcp?.title { info["title"] = .string(title) }
            var result: JSONObject = [
                "protocolVersion": .string(Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0]),
                "capabilities": ["tools": ["listChanged": true]],
                "serverInfo": .object(info),
            ]
            if let instructions = cli.mcp?.instructions { result["instructions"] = .string(instructions) }
            return .object(result)
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": .array(listedTools())]
        case "tools/call":
            guard let name = params["name"]?.stringValue else { throw RpcError(code: -32602, message: "Missing tool name") }
            let arguments = params["arguments"]?.objectValue ?? JSONObject()
            let token = params["_meta"]?["progressToken"]
            return try await callListedTool(name, arguments, progressToken: token)
        default:
            throw RpcError(code: -32601, message: "Method not found")
        }
    }

    // MARK: Tools

    private func listedTools() -> [JSON] {
        guard discovery == .progressive, !tools.isEmpty else { return tools.map(directDefinition) }
        let name: JSON = ["type": "string", "minLength": 1, "description": "Exact tool name."]
        let call: JSON = [
            "type": "object", "$schema": .string(Self.jsonSchemaDialect),
            "properties": ["name": name, "arguments": ["default": [:], "description": "Arguments from its schema.", "type": "object",
                                                       "propertyNames": ["type": "string"], "additionalProperties": [:]]],
            "required": ["name"],
        ]
        return [
            definition("search_tools",
                       "Search or page through available tools by capability. Returns names and descriptions without loading their schemas. Inspect a result before calling it.",
                       Self.inputSchema(["limit": Schema.int.min(1).max(20).default(5).describe("Maximum matches."),
                                         "offset": Schema.int.min(0).default(0).describe("Matches to skip."),
                                         "query": Schema.string.default("").describe("Capability to find. Empty lists all tools.")]),
                       Self.catalogAnnotations),
            definition("get_tool_details", "Inspect one tool returned by search_tools. Returns its complete input schema and metadata.",
                       ["type": "object", "$schema": .string(Self.jsonSchemaDialect), "properties": ["name": name], "required": ["name"]],
                       Self.catalogAnnotations),
            definition("call_read_tool", "Execute a tool marked read-only after inspecting its schema with get_tool_details.",
                       call, Self.readAnnotations),
            definition("call_write_tool", "Execute a writable or unclassified tool after inspecting its schema with get_tool_details.",
                       call, Self.writeAnnotations),
        ]
    }

    static let jsonSchemaDialect = "https://json-schema.org/draft/2020-12/schema"

    /// Input schema as MCP clients see it: fields with defaults are optional.
    static func inputSchema(_ shape: Shape) -> JSON {
        guard !shape.isEmpty else { return ["type": "object", "properties": [:]] }
        var properties = JSONObject()
        for field in shape.fields { properties[field.name] = field.schema.jsonSchema }
        var object: JSONObject = ["type": "object", "$schema": .string(jsonSchemaDialect), "properties": .object(properties)]
        let required = shape.fields.filter(\.schema.isRequired).map { JSON.string($0.name) }
        if !required.isEmpty { object["required"] = .array(required) }
        return .object(object)
    }

    private func definition(_ name: String, _ description: String, _ input: JSON, _ annotations: ToolAnnotations) -> JSON {
        ["name": .string(name), "description": .string(description), "inputSchema": input, "annotations": annotations.json]
    }

    private func directDefinition(_ tool: ToolEntry) -> JSON {
        var object: JSONObject = ["name": .string(tool.name)]
        if let description = tool.description { object["description"] = .string(description) }
        object["inputSchema"] = Self.inputSchema(Shape((tool.command.args?.fields ?? []) + (tool.command.options?.fields ?? [])))
        if let output = tool.outputSchema { object["outputSchema"] = output }
        if let annotations = tool.annotations { object["annotations"] = annotations.json }
        if let instructions = tool.instructions { object["_meta"] = ["instructions": .string(instructions)] }
        return .object(object)
    }

    static let catalogAnnotations = ToolAnnotations(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    static let readAnnotations = ToolAnnotations(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: true)
    static let writeAnnotations = ToolAnnotations(readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true)

    private func callListedTool(_ name: String, _ arguments: JSONObject, progressToken: JSON?) async throws -> JSON {
        guard discovery == .progressive else {
            guard let tool = tools.first(where: { $0.name == name }) else { throw RpcError(code: -32602, message: "Tool \(name) not found") }
            return await call(tool, arguments, progressToken: progressToken)
        }
        switch name {
        case "search_tools":
            let limit = arguments["limit"]?.intValue ?? 5
            let offset = arguments["offset"]?.intValue ?? 0
            let matches = search(arguments["query"]?.stringValue ?? "")
            let page = Array(matches.dropFirst(offset).prefix(limit))
            var result: JSONObject = ["tools": .array(page.map(\.summary))]
            if offset + page.count < matches.count { result["nextOffset"] = .number(Double(offset + page.count)) }
            return Self.toolResult(.object(result))
        case "get_tool_details":
            let toolName = arguments["name"]?.stringValue ?? ""
            guard let tool = tools.first(where: { $0.name == toolName }) else { return Self.toolError("Unknown tool: \(toolName)") }
            var result: JSONObject = ["name": .string(tool.name)]
            if let description = tool.description { result["description"] = .string(description) }
            result["inputSchema"] = tool.inputSchema
            if let output = tool.outputSchema { result["outputSchema"] = output }
            if let annotations = tool.annotations { result["annotations"] = annotations.json }
            if let instructions = tool.instructions { result["instructions"] = .string(instructions) }
            return Self.toolResult(.object(result))
        case "call_read_tool", "call_write_tool":
            let toolName = arguments["name"]?.stringValue ?? ""
            guard let tool = tools.first(where: { $0.name == toolName }) else { return Self.toolError("Unknown tool: \(toolName)") }
            let readOnly = tool.annotations?.readOnlyHint == true
            if name == "call_read_tool", !readOnly { return Self.toolError("Tool is not read-only: \(toolName)") }
            if name == "call_write_tool", readOnly { return Self.toolError("Tool is read-only: \(toolName)") }
            return await call(tool, arguments["arguments"]?.objectValue ?? JSONObject(), progressToken: progressToken)
        default:
            throw RpcError(code: -32602, message: "Tool \(name) not found")
        }
    }

    private func search(_ query: String) -> [ToolEntry] {
        func normalize(_ text: String) -> String {
            text.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        let normalized = normalize(query)
        let terms = normalized.split(separator: " ").map(String.init)
        return tools.map { tool -> (ToolEntry, Int) in
            let name = normalize(tool.name), description = normalize(tool.description ?? "")
            if name == normalized { return (tool, 1_000) }
            var score = name.hasPrefix(normalized) ? 100 : name.contains(normalized) ? 50 : 0
            for term in terms {
                if name.split(separator: " ").contains(Substring(term)) { score += 20 } else if name.contains(term) { score += 10 }
                if description.contains(term) { score += 2 }
            }
            return (tool, score)
        }
        .filter { $0.1 > 0 }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : localeCompare($0.0.name, $1.0.name) < 0 }
        .map(\.0)
    }

    static func toolResult(_ value: JSON) -> JSON {
        ["content": [["type": "text", "text": .string(JSONWriter.stringify(value))]]]
    }

    static func toolError(_ message: String) -> JSON {
        ["content": [["type": "text", "text": .string(JSONWriter.stringify(["error": .string(message)]))]], "isError": true]
    }

    private func call(_ tool: ToolEntry, _ params: JSONObject, progressToken: JSON?) async -> JSON {
        let result = await Executor.execute(tool.command, .init(
            agent: true, argv: [], defaults: nil, displayName: serverName, cliEnv: cli.env, environment: runtime.io.environment,
            format: .json, formatExplicit: true, globals: [:], input: params,
            middlewares: cli.middlewares + tool.middlewares + tool.command.middleware, name: serverName, path: tool.name,
            vars: cli.vars, version: cli.version
        ))
        func text(_ body: String, _ cta: FormattedCtaBlock?) -> JSON {
            .string(cta.map { "\(body)\n\n\($0.text)" } ?? body)
        }
        switch result {
        case .stream(let body):
            var chunks: [JSON] = []
            var progress = 0
            let emitter = Emitter { [self] chunk in
                chunks.append(chunk)
                if let progressToken {
                    progress += 1
                    send(["jsonrpc": "2.0", "method": "notifications/progress",
                          "params": ["progressToken": progressToken, "progress": .number(Double(progress)),
                                     "message": .string(JSONWriter.stringify(chunk))]])
                }
            }
            do {
                _ = try await body(emitter)
            } catch {
                return ["content": [["type": "text", "text": .string(errorMessage(error))]], "isError": true]
            }
            return ["content": [["type": "text", "text": .string(JSONWriter.stringify(.array(chunks)))]]]
        case .error(let info, let cta, _):
            let block = FormattedCtaBlock.make(serverName, cta)
            let body = info.fieldErrors != nil ? JSONWriter.stringify(info.json) : info.message
            var object: JSONObject = ["content": [["type": "text", "text": text(body, block)]]]
            if let block { object["_meta"] = ["cta": block.json] }
            object["isError"] = true
            return .object(object)
        case .ok(let data, let cta):
            let value = data ?? .null
            let block = FormattedCtaBlock.make(serverName, cta)
            var object: JSONObject = ["content": [["type": "text", "text": text(JSONWriter.stringify(value), block)]]]
            if !value.isNull, tool.outputSchema != nil { object["structuredContent"] = value }
            if let block { object["_meta"] = ["cta": block.json] }
            return .object(object)
        }
    }

    // MARK: Collection

    func collectTools() throws -> [ToolEntry] {
        var tools = collect(cli.commands, prefix: [], middlewares: [])
        if let root = cli.root, root.mcp?.isHidden != true {
            tools.append(entry(root, path: [cli.name], middlewares: []))
        }
        let filter = cli.mcp?.tools
        let includes = filter?.include?.map(Self.pattern) ?? []
        let excludes = filter?.exclude?.map(Self.pattern) ?? []
        tools = tools.filter { tool in
            if excludes.contains(where: { tool.name.range(of: $0, options: .regularExpression) != nil }) { return false }
            return includes.isEmpty || includes.contains { tool.name.range(of: $0, options: .regularExpression) != nil }
        }
        var seen = Set<String>()
        for tool in tools where !seen.insert(tool.name).inserted { throw ParseError("Duplicate MCP tool name: \(tool.name)") }
        return tools.sorted { localeCompare($0.name, $1.name) < 0 }
    }

    private func collect(_ commands: Commands, prefix: [String], middlewares: [Middleware]) -> [ToolEntry] {
        commands.canonical.flatMap { name, entry -> [ToolEntry] in
            let path = prefix + [name]
            switch entry {
            case .command(let command):
                return command.mcp?.isHidden == true ? [] : [self.entry(command, path: path, middlewares: middlewares)]
            case .group(let group):
                guard !group.mcpHidden else { return [] }
                let inherited = middlewares + group.middlewares
                var result: [ToolEntry] = []
                if let root = group.root, root.mcp?.isHidden != true { result.append(self.entry(root, path: path, middlewares: inherited)) }
                return result + collect(group.commands, prefix: path, middlewares: inherited)
            case .alias:
                return []
            }
        }
    }

    private func entry(_ command: Command, path: [String], middlewares: [Middleware]) -> ToolEntry {
        var properties = JSONObject()
        var required: [JSON] = []
        for shape in [command.args, command.options].compactMap({ $0 }) {
            let schema = Schema.objectSchema(shape)
            for (key, value) in schema["properties"]?.objectValue ?? JSONObject() { properties[key] = value }
            required += schema["required"]?.arrayValue ?? []
        }
        var input: JSONObject = ["type": "object", "properties": .object(properties)]
        if !required.isEmpty { input["required"] = .array(required) }
        let output = command.output.map(\.jsonSchema).flatMap { $0["type"]?.stringValue == "object" ? $0 : nil }
        return ToolEntry(name: command.mcp?.name ?? path.joined(separator: "_"),
                         description: command.mcp?.description ?? command.description, inputSchema: .object(input),
                         outputSchema: output, annotations: command.mcp?.annotations, instructions: command.mcp?.instructions,
                         command: command, path: path.joined(separator: " "), middlewares: middlewares)
    }

    private static func pattern(_ glob: String) -> String {
        "^" + NSRegularExpression.escapedPattern(for: glob).replacingOccurrences(of: "\\*", with: ".*") + "$"
    }

    // MARK: Doctor

    /// Starts the server in-process, sends `initialize` and `tools/list`, and reports what it saw.
    func doctor() async -> JSON {
        discovery = .direct
        var warnings: [JSON] = []
        var errors: [JSON] = []
        do {
            tools = try collectTools()
        } catch {
            return ["ok": false, "toolCount": 0, "tools": [], "warnings": [],
                    "errors": [["code": "MCP_SERVER_FAILED", "message": .string(errorMessage(error))]]]
        }
        let initialize = await handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"swiftcur-doctor","version":"1.0.0"}}}"#)
        let list = await handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#)
        if initialize == nil {
            errors.append(["code": "MCP_INITIALIZE_MISSING", "message": "Missing initialize response."])
        } else if let error = initialize?["error"] {
            errors.append(["code": "MCP_INITIALIZE_FAILED", "message": error["message"] ?? .string(error.description)])
        }
        var listed: [JSON] = []
        if list == nil {
            errors.append(["code": "MCP_TOOLS_LIST_MISSING", "message": "Missing tools/list response."])
        } else if let error = list?["error"] {
            errors.append(["code": "MCP_TOOLS_LIST_FAILED", "message": error["message"] ?? .string(error.description)])
        } else if let items = list?["result"]?["tools"]?.arrayValue {
            listed = items.compactMap { tool in
                guard let name = tool["name"]?.stringValue, !name.isEmpty else { return nil }
                var object: JSONObject = ["name": .string(name)]
                if let description = tool["description"]?.stringValue { object["description"] = .string(description) }
                return .object(object)
            }
        } else {
            errors.append(["code": "MCP_TOOLS_LIST_INVALID", "message": "tools/list did not return a tools array."])
        }
        if errors.isEmpty, listed.isEmpty { warnings.append("No MCP tools exposed.") }
        return ["ok": .bool(errors.isEmpty), "toolCount": .number(Double(listed.count)), "tools": .array(listed),
                "warnings": .array(warnings), "errors": .array(errors)]
    }
}

/// Registers the CLI's MCP server in coding agents' config files.
struct McpRegistrar {
    struct Target {
        var id: String
        var name: String
        var detect: String
        var write: (_ name: String, _ command: [String], _ global: Bool, _ cwd: String) throws -> Bool
    }

    let environment: [String: String]
    var home: String { environment["HOME"] ?? NSHomeDirectory() }

    func register(name: String, command: String, agents: [String], global: Bool, cwd: String)
        -> (command: String, agents: [String], errors: [String]) {
        let tokens = splitCommand(command)
        let targets = self.targets()
        let selected = agents.isEmpty
            ? targets.filter { FileManager.default.fileExists(atPath: $0.detect) }
            : targets.filter { agents.contains($0.id) }
        var registered: [String] = []
        var errors: [String] = []
        for agent in agents where !targets.contains(where: { $0.id == agent }) {
            errors.append("Unknown agent '\(agent)'. Supported: \(targets.map(\.id).joined(separator: ", "))")
        }
        for target in selected {
            do {
                if try target.write(name, tokens, global, cwd) { registered.append(target.name) }
            } catch {
                errors.append("\(target.name): \(errorMessage(error))")
            }
        }
        if selected.isEmpty, errors.isEmpty { errors.append("No supported agents detected. Pass --agent <id>.") }
        return (command, registered, errors)
    }

    private func targets() -> [Target] {
        let config = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.config"
        let claude = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.claude"
        let codex = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.codex"
        return [
            Target(id: "claude-code", name: "Claude Code", detect: claude) { name, command, global, cwd in
                try writeServers(global ? "\(home)/.claude.json" : "\(cwd)/.mcp.json", key: ["mcpServers"], name: name,
                                 value: ["type": "stdio", "command": .string(command[0]), "args": .array(command.dropFirst().map(JSON.string))])
            },
            Target(id: "cursor", name: "Cursor", detect: "\(home)/.cursor") { name, command, global, cwd in
                try writeServers(global ? "\(home)/.cursor/mcp.json" : "\(cwd)/.cursor/mcp.json", key: ["mcpServers"], name: name,
                                 value: stdio(command))
            },
            Target(id: "codex", name: "Codex", detect: codex) { name, command, global, cwd in
                try writeCodex(global ? "\(codex)/config.toml" : "\(cwd)/.codex/config.toml", name: name, command: command)
            },
            Target(id: "gemini-cli", name: "Gemini CLI", detect: "\(home)/.gemini") { name, command, global, cwd in
                try writeServers(global ? "\(home)/.gemini/settings.json" : "\(cwd)/.gemini/settings.json", key: ["mcpServers"],
                                 name: name, value: stdio(command))
            },
            Target(id: "windsurf", name: "Windsurf", detect: "\(home)/.codeium/windsurf") { name, command, _, _ in
                try writeServers("\(home)/.codeium/windsurf/mcp_config.json", key: ["mcpServers"], name: name, value: stdio(command))
            },
            Target(id: "vscode", name: "VS Code", detect: "\(home)/Library/Application Support/Code/User") { name, command, global, cwd in
                try writeServers(global ? "\(home)/Library/Application Support/Code/User/mcp.json" : "\(cwd)/.vscode/mcp.json",
                                 key: ["servers"], name: name,
                                 value: ["type": "stdio", "command": .string(command[0]), "args": .array(command.dropFirst().map(JSON.string))])
            },
            Target(id: "opencode", name: "OpenCode", detect: "\(config)/opencode") { name, command, global, cwd in
                try writeServers(global ? "\(config)/opencode/opencode.json" : "\(cwd)/opencode.json", key: ["mcp"], name: name,
                                 value: ["type": "local", "command": .array(command.map(JSON.string)), "enabled": true])
            },
            Target(id: "amp", name: "Amp", detect: "\(config)/amp") { name, command, _, _ in
                try writeServers("\(config)/amp/settings.json", key: ["amp.mcpServers"], name: name, value: stdio(command))
            },
        ]
    }

    private func stdio(_ command: [String]) -> JSON {
        ["command": .string(command[0]), "args": .array(command.dropFirst().map(JSON.string))]
    }

    /// Sets `config[key...][name] = value`, keeping the rest of the file and its key order.
    private func writeServers(_ file: String, key path: [String], name: String, value: JSON) throws -> Bool {
        let manager = FileManager.default
        var root = JSONObject()
        if let data = manager.contents(atPath: file), !data.isEmpty {
            guard let parsed = try? JSONParser.parse(String(decoding: data, as: UTF8.self)).objectValue else {
                throw ParseError("\(file) is not a JSON object; left unchanged")
            }
            root = parsed
        }
        func set(_ object: JSONObject, _ keys: ArraySlice<String>) -> JSONObject {
            var copy = object
            guard let first = keys.first else { return copy }
            if keys.count == 1 {
                var servers = copy[first]?.objectValue ?? JSONObject()
                servers[name] = value
                copy[first] = .object(servers)
            } else {
                copy[first] = .object(set(copy[first]?.objectValue ?? JSONObject(), keys.dropFirst()))
            }
            return copy
        }
        root = set(root, path[...])
        try manager.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try (JSONWriter.stringify(.object(root), indent: 2) + "\n").write(toFile: file, atomically: true, encoding: .utf8)
        return true
    }

    /// Replaces or appends a `[mcp_servers.<name>]` table in Codex's TOML config.
    private func writeCodex(_ file: String, name: String, command: [String]) throws -> Bool {
        let existing = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        let header = "[mcp_servers.\(name.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil ? name : JSONWriter.quote(name))]"
        var lines: [String] = []
        var skipping = false
        for line in existing.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { skipping = trimmed == header || trimmed.hasPrefix(String(header.dropLast()) + ".") }
            if !skipping { lines.append(line) }
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        let args = command.dropFirst().map { JSONWriter.quote($0) }.joined(separator: ", ")
        if !lines.isEmpty { lines.append("") }
        lines += [header, "command = \(JSONWriter.quote(command[0]))", "args = [\(args)]", ""]
        try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(toFile: file, atomically: true, encoding: .utf8)
        return true
    }
}
