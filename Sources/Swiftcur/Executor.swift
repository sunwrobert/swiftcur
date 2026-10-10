import Foundation

/// Runs a command for any transport: argv, or flat MCP arguments.
enum Executor {
    struct Options {
        var agent: Bool
        /// Raw tokens after the command path. Empty for MCP.
        var argv: [String]
        var defaults: JSONObject?
        var displayName: String
        var cliEnv: Shape?
        var environment: [String: String]
        var format: Format
        var formatExplicit: Bool
        var globals: JSONObject
        /// Flat MCP arguments, split into args and options by name. `nil` means parse argv.
        var input: JSONObject?
        var middlewares: [Middleware]
        var name: String
        var path: String
        var vars: JSONObject
        var version: String?
    }

    enum Result {
        case ok(JSON?, cta: CtaBlock?)
        case error(ErrorInfo, cta: CtaBlock?, exitCode: Int32?)
        case stream(@Sendable (Emitter) async throws -> Response?)
    }

    static func execute(_ command: Command, _ options: Options) async -> Result {
        let vars = Vars(defaults: options.vars)
        do {
            let cliEnv = try options.cliEnv.map { try Parser.parseEnv($0, options.environment) } ?? JSONObject()
            var result: Result?

            let runCommand: @Sendable () async throws -> Void = {
                let (args, parsedOptions) = try parseInput(command, options)
                let env = try command.env.map { try Parser.parseEnv($0, options.environment) } ?? JSONObject()
                let context = Context(agent: options.agent, args: args, options: parsedOptions, env: env, globals: options.globals,
                                      format: options.format, formatExplicit: options.formatExplicit, name: options.name,
                                      displayName: options.displayName, version: options.version, vars: vars)
                result = convert(try await command.run(context))
            }

            guard !options.middlewares.isEmpty else {
                try await runCommand()
                return result ?? .ok(nil, cta: nil)
            }

            let context = MiddlewareContext(agent: options.agent, command: options.path, displayName: options.displayName,
                                            env: cliEnv, format: options.format, formatExplicit: options.formatExplicit,
                                            globals: options.globals, name: options.name, version: options.version, vars: vars)
            let chain = options.middlewares.reversed().reduce(runCommand) { next, middleware in
                { @Sendable in
                    guard context.failure == nil else { return }
                    try await middleware(context, next)
                }
            }
            try await chain()
            if let failure = context.failure { return convert(failure) }
            return result ?? .ok(nil, cta: nil)
        } catch {
            let (info, exitCode) = ErrorInfo.from(error)
            return .error(info, cta: nil, exitCode: exitCode)
        }
    }

    private static func parseInput(_ command: Command, _ options: Options) throws -> (JSONObject, JSONObject) {
        guard let input = options.input else {
            return try Parser.parse(options.argv, args: command.args, options: command.options, alias: command.alias,
                                    defaults: options.defaults)
        }
        let argNames = Set(command.args?.names ?? [])
        var args = JSONObject(), rest = JSONObject()
        for (key, value) in input {
            if argNames.contains(key) { args[key] = value } else { rest[key] = value }
        }
        return (try command.args.map { try Schema.parse($0, args) } ?? JSONObject(),
                try command.options.map { try Schema.parse($0, rest) } ?? JSONObject())
    }

    static func convert(_ response: Response) -> Result {
        switch response.kind {
        case .ok(let data): return .ok(data, cta: response.cta)
        case .error(let error):
            let info = ErrorInfo(code: error.code, message: error.message, retryable: response.retryableSet ? error.retryable : nil)
            return .error(info, cta: response.cta, exitCode: error.exitCode)
        case .stream(let body): return .stream(body)
        }
    }
}

/// Writes results according to the output flags.
final class OutputWriter {
    let runtime: Runtime
    let flags: BuiltinFlags
    let format: Format
    let notice: FormattedCtaBlock?
    let renderOutput: Bool
    let filter: [[Filter.Segment]]?

    init(runtime: Runtime, flags: BuiltinFlags, format: Format, notice: FormattedCtaBlock?, outputPolicy: OutputPolicy) {
        self.runtime = runtime
        self.flags = flags
        self.format = format
        self.notice = notice
        renderOutput = !(runtime.human && !flags.formatExplicit && outputPolicy == .agentOnly)
        filter = flags.filterOutput.map(Filter.parse)
    }

    private func writeln(_ text: String) { runtime.writeln(text) }

    func truncate(_ text: String) -> (text: String, truncated: Bool, nextOffset: Int?) {
        guard flags.tokenLimit != nil || flags.tokenOffset != nil else { return (text, false, nil) }
        let total = Tokens.count(text)
        let offset = flags.tokenOffset ?? 0
        let end = flags.tokenLimit.map { offset + $0 } ?? total
        if offset == 0, end >= total { return (text, false, nil) }
        let actualEnd = min(end, total)
        let sliced = Tokens.slice(text, from: offset, to: end)
        return ("\(sliced)\n[truncated: showing tokens \(offset)–\(actualEnd) of \(total)]", true, actualEnd < total ? actualEnd : nil)
    }

    func write(_ given: Output) {
        var output = given
        if let filter, output.ok, let data = output.data, !data.isNull { output.data = Filter.apply(data, filter) }
        if let notice {
            let existing = output.meta["cta"]
            let merged: JSON
            if let existing, let commands = existing["commands"]?.arrayValue {
                merged = ["description": existing["description"] ?? .null,
                          "commands": .array(commands + notice.commands.map(\.json))]
            } else {
                merged = notice.json
            }
            output.meta["cta"] = merged
        }

        if flags.tokenCount {
            let base = output.ok ? output.data : output.error?.json
            writeln(String(Tokens.count(base.map { Formatter.format($0, format) } ?? "")))
            return
        }

        let cta = output.meta["cta"]
        if runtime.human, !flags.fullOutput {
            if output.ok, let data = output.data, !data.isNull, renderOutput {
                writeln(truncate(Formatter.format(data, format)).text)
            } else if !output.ok, let error = output.error {
                writeln(HumanError.format(code: error.code, message: error.message, fieldErrors: error.fieldErrors))
            }
            if let cta, let block = Self.block(cta) { writeln(block.human) }
            return
        }

        if flags.fullOutput {
            if flags.tokenLimit != nil || flags.tokenOffset != nil {
                let text = output.ok ? Formatter.format(output.data, format) : Formatter.format(output.error?.json, format)
                let result = truncate(text)
                if result.truncated {
                    var envelope: JSONObject = output.ok ? ["ok": true, "data": .string(result.text)] : ["ok": false, "error": .string(result.text)]
                    var meta = output.meta
                    if let next = result.nextOffset { meta["nextOffset"] = .number(Double(next)) }
                    envelope["meta"] = .object(meta)
                    writeln(Formatter.format(.object(envelope), format))
                    return
                }
            }
            writeln(Formatter.format(output.json, format))
            return
        }

        let base: JSON? = output.ok ? output.data : output.error?.json
        guard let cta else {
            let text = Formatter.format(base, format)
            if !text.isEmpty { writeln(truncate(text).text) }
            return
        }
        let payload: JSON
        if let object = base?.objectValue {
            var merged = object
            merged["cta"] = cta
            payload = .object(merged)
        } else {
            payload = ["data": base ?? .null, "cta": cta]
        }
        writeln(truncate(Formatter.format(payload, format)).text)
    }

    static func block(_ json: JSON) -> FormattedCtaBlock? {
        guard let description = json["description"]?.stringValue, let commands = json["commands"]?.arrayValue else { return nil }
        return FormattedCtaBlock(description: description, commands: commands.map {
            FormattedCta(command: $0["command"]?.stringValue ?? "", description: $0["description"]?.stringValue)
        })
    }

    func writeResult(_ result: Executor.Result, command: Command, path: String) async -> Int32 {
        let name = runtime.displayName
        switch result {
        case .stream(let body):
            return await writeStream(body, path: path)
        case .ok(let data, let cta):
            var meta: JSONObject = ["command": .string(path), "duration": .string(runtime.duration)]
            if let block = FormattedCtaBlock.make(name, cta) { meta["cta"] = block.json }
            write(Output(ok: true, data: data, meta: meta))
            return 0
        case .error(let info, let cta, let exitCode):
            if runtime.human, !flags.formatExplicit, let fieldErrors = info.fieldErrors {
                writeln(validationHelp(name: name, path: path, command: command, fieldErrors: fieldErrors))
                return 1
            }
            var meta: JSONObject = ["command": .string(path), "duration": .string(runtime.duration)]
            if let block = FormattedCtaBlock.make(name, cta) { meta["cta"] = block.json }
            write(Output(ok: false, error: info, meta: meta))
            return exitCode ?? 1
        }
    }

    private func validationHelp(name: String, path: String, command: Command, fieldErrors: [FieldError]) -> String {
        var lines = fieldErrors.map { field -> String in
            let head = field.path.split(separator: ".").first.map(String.init) ?? ""
            let tail = field.path.split(separator: ".").dropFirst().map { ".\($0)" }.joined()
            let (kind, label): (String, String)
            if head.isEmpty {
                (kind, label) = ("argument", "input")
            } else if command.options?[head] != nil {
                (kind, label) = ("option", "--\(toKebab(head))\(tail)")
            } else if command.env?[head] != nil {
                (kind, label) = ("environment variable", "\(head)\(tail)")
            } else {
                (kind, label) = ("argument", "<\(field.path)>")
            }
            if field.missing { return "Error: missing required \(kind) \(label)" }
            if kind == "environment variable" { return "Error: invalid value for environment variable \(label): \(field.message)" }
            return "Error: invalid value for \(label): \(field.message)"
        }
        lines += ["See below for usage.", ""]
        var options = runtime.commandHelp(command, name: path, isRoot: false)
        options.aliases = []
        options.globals = nil
        options.hideGlobalOptions = false
        options.root = false
        options.version = nil
        lines.append(Help.formatCommand(path == runtime.name ? name : "\(name) \(path)", options))
        return lines.joined(separator: "\n")
    }

    // MARK: Streaming

    private func writeStream(_ body: @escaping @Sendable (Emitter) async throws -> Response?, path: String) async -> Int32 {
        let jsonl = format == .jsonl
        let incremental = jsonl || (!flags.formatExplicit && format == .toon)
        var chunks: [JSON] = []
        let emitter = Emitter { [self] chunk in
            if !incremental {
                chunks.append(chunk)
            } else if jsonl {
                writeln(JSONWriter.stringify(["type": "chunk", "data": chunk]))
            } else if renderOutput {
                writeln(truncate(Formatter.format(chunk, format)).text)
            }
        }
        do {
            let final = try await body(emitter)
            if let final, case .error(let error) = final.kind {
                return writeStreamError(code: error.code, message: error.message,
                                        retryable: final.retryableSet ? error.retryable : nil, exitCode: error.exitCode,
                                        incremental: incremental, path: path)
            }
            let cta = FormattedCtaBlock.make(runtime.displayName, final?.cta)
            if incremental {
                if jsonl {
                    var meta: JSONObject = ["command": .string(path), "duration": .string(runtime.duration)]
                    if let cta { meta["cta"] = cta.json }
                    writeln(JSONWriter.stringify(["type": "done", "ok": true, "meta": .object(meta)]))
                } else if let cta {
                    writeln(cta.human)
                }
            } else {
                var meta: JSONObject = ["command": .string(path), "duration": .string(runtime.duration)]
                if let cta { meta["cta"] = cta.json }
                write(Output(ok: true, data: .array(chunks), meta: meta))
            }
            return 0
        } catch {
            let (info, exitCode) = ErrorInfo.from(error)
            let retryable = (error as? CommandError).map(\.retryable)
            if incremental, !jsonl {
                writeln(HumanError.format(code: "UNKNOWN", message: info.message))
                return exitCode ?? 1
            }
            return writeStreamError(code: info.code, message: info.message, retryable: retryable, exitCode: exitCode,
                                    incremental: incremental, path: path)
        }
    }

    private func writeStreamError(code: String, message: String, retryable: Bool?, exitCode: Int32?, incremental: Bool,
                                  path: String) -> Int32 {
        var error: JSONObject = ["code": .string(code), "message": .string(message)]
        if let retryable { error["retryable"] = .bool(retryable) }
        if format == .jsonl {
            writeln(JSONWriter.stringify(["type": "error", "ok": false, "error": .object(error)]))
        } else if incremental {
            writeln(HumanError.format(code: code, message: message))
        } else {
            write(Output(ok: false, error: ErrorInfo(code: code, message: message, retryable: retryable),
                         meta: ["command": .string(path), "duration": .string(runtime.duration)]))
        }
        return exitCode ?? 1
    }
}
