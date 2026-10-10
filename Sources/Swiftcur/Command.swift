import Foundation

/// Who sees a command's data output.
public enum OutputPolicy: String, Sendable {
    /// Humans and agents.
    case all
    /// Agents only: data is hidden in a TTY unless `--format`/`--json` is passed.
    case agentOnly = "agent-only"
}

/// A suggested next command.
public struct Cta: ExpressibleByStringLiteral, Sendable {
    public var command: String
    public var description: String?
    /// Positional values. `true` renders a `<name>` placeholder.
    public var args: [(String, JSON)]
    /// Option values. `true` renders `--name <name>`.
    public var options: [(String, JSON)]

    public init(_ command: String, description: String? = nil, args: [(String, JSON)] = [], options: [(String, JSON)] = []) {
        self.command = command
        self.description = description
        self.args = args
        self.options = options
    }

    public init(stringLiteral value: String) { self.init(value) }
}

/// Suggested next commands attached to a result.
public struct CtaBlock: ExpressibleByArrayLiteral, Sendable {
    public var description: String?
    public var commands: [Cta]

    public init(description: String? = nil, commands: [Cta]) {
        self.description = description
        self.commands = commands
    }

    public init(arrayLiteral elements: Cta...) { self.init(commands: elements) }
}

/// A usage example shown in help and skills.
public struct Example: Sendable {
    public var args: [(String, JSON)]
    public var options: [(String, JSON)]
    public var description: String?

    public init(args: [(String, JSON)] = [], options: [(String, JSON)] = [], description: String? = nil) {
        self.args = args
        self.options = options
        self.description = description
    }

    /// The args and options rendered as a command suffix.
    var suffix: String {
        (args.map { $0.1.plainText } + options.map { "--\($0.0) \($0.1.plainText)" }).joined(separator: " ")
    }
}

/// An alternative usage line in help.
public struct Usage: Sendable {
    public var prefix: String?
    public var args: [String]
    public var options: [String]
    public var suffix: String?

    public init(prefix: String? = nil, args: [String] = [], options: [String] = [], suffix: String? = nil) {
        self.prefix = prefix
        self.args = args
        self.options = options
        self.suffix = suffix
    }
}

/// MCP behavior hints for a tool.
public struct ToolAnnotations: Sendable, Equatable {
    public var title: String?
    public var readOnlyHint: Bool?
    public var destructiveHint: Bool?
    public var idempotentHint: Bool?
    public var openWorldHint: Bool?

    public init(title: String? = nil, readOnlyHint: Bool? = nil, destructiveHint: Bool? = nil,
                idempotentHint: Bool? = nil, openWorldHint: Bool? = nil) {
        self.title = title
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint
        self.openWorldHint = openWorldHint
    }

    var json: JSON {
        var object = JSONObject()
        if let title { object["title"] = .string(title) }
        if let readOnlyHint { object["readOnlyHint"] = .bool(readOnlyHint) }
        if let destructiveHint { object["destructiveHint"] = .bool(destructiveHint) }
        if let idempotentHint { object["idempotentHint"] = .bool(idempotentHint) }
        if let openWorldHint { object["openWorldHint"] = .bool(openWorldHint) }
        return .object(object)
    }
}

/// How a command appears to MCP clients.
public enum ToolExposure: Sendable {
    case hidden
    case tool(name: String? = nil, description: String? = nil, annotations: ToolAnnotations? = nil, instructions: String? = nil)

    public static func annotations(_ annotations: ToolAnnotations) -> ToolExposure {
        .tool(annotations: annotations)
    }

    var isHidden: Bool {
        if case .hidden = self { return true }
        return false
    }

    var name: String? {
        if case .tool(let name, _, _, _) = self { return name }
        return nil
    }

    var description: String? {
        if case .tool(_, let description, _, _) = self { return description }
        return nil
    }

    var annotations: ToolAnnotations? {
        if case .tool(_, _, let annotations, _) = self { return annotations }
        return nil
    }

    var instructions: String? {
        if case .tool(_, _, _, let instructions) = self { return instructions }
        return nil
    }
}

/// What a command returns.
public struct Response: Sendable {
    enum Kind: @unchecked Sendable {
        case ok(JSON?)
        case error(CommandError)
        case stream(@Sendable (Emitter) async throws -> Response?)
    }

    let kind: Kind
    let cta: CtaBlock?

    /// Success with data.
    public static func ok(_ data: JSON? = nil, cta: CtaBlock? = nil) -> Response {
        Response(kind: .ok(data), cta: cta)
    }

    /// Success with any `Encodable` value.
    public static func value<T: Encodable>(_ data: T, cta: CtaBlock? = nil) throws -> Response {
        Response(kind: .ok(try JSON(encoding: data)), cta: cta)
    }

    /// Failure with a code and optional suggested commands.
    public static func error(code: String, message: String, cta: CtaBlock? = nil, exitCode: Int32? = nil,
                             retryable: Bool? = nil) -> Response {
        let error = CommandError(code: code, message: message, retryable: retryable ?? false, exitCode: exitCode)
        return Response(kind: .error(error), cta: cta, retryableSet: retryable != nil)
    }

    /// Streams chunks through the emitter. Return `.ok(cta:)` or `.error(…)` to finish, or `nil`.
    public static func stream(_ body: @escaping @Sendable (Emitter) async throws -> Response?) -> Response {
        Response(kind: .stream(body), cta: nil)
    }

    let retryableSet: Bool

    init(kind: Kind, cta: CtaBlock?, retryableSet: Bool = false) {
        self.kind = kind
        self.cta = cta
        self.retryableSet = retryableSet
    }
}

/// Receives streamed chunks.
public final class Emitter: @unchecked Sendable {
    let handler: (JSON) async throws -> Void

    init(_ handler: @escaping (JSON) async throws -> Void) { self.handler = handler }

    public func emit(_ value: JSON) async throws { try await handler(value) }

    public func emit<T: Encodable>(_ value: T) async throws { try await handler(try JSON(encoding: value)) }
}

/// Values shared between middleware and the command.
public final class Vars: @unchecked Sendable {
    private var values: [String: Any] = [:]

    init(defaults: JSONObject) {
        for (key, value) in defaults { values[key] = value }
    }

    public subscript<T>(key: String) -> T? {
        get { values[key] as? T }
        set { values[key] = newValue }
    }

    public func set(_ key: String, _ value: Any) { values[key] = value }

    public func get<T>(_ key: String, as type: T.Type = T.self) -> T? { values[key] as? T }
}

/// Everything a command handler receives.
public struct Context: @unchecked Sendable {
    /// `true` when stdout is not a TTY (an agent or a pipe).
    public let agent: Bool
    public let args: JSONObject
    public let options: JSONObject
    public let env: JSONObject
    public let globals: JSONObject
    public let format: Format
    public let formatExplicit: Bool
    public let name: String
    /// The binary name the user typed, which may be an alias.
    public let displayName: String
    public let version: String?
    public let vars: Vars

    /// Decodes positional args into a `Decodable` type. Pass `options: true` to merge options in too.
    public func args<T: Decodable>(as type: T.Type, options includeOptions: Bool = false) throws -> T {
        try JSON.object(includeOptions ? args.merging(options) : args).decode(type)
    }

    /// Decodes options into a `Decodable` type.
    public func options<T: Decodable>(as type: T.Type) throws -> T { try JSON.object(options).decode(type) }

    /// Decodes env vars into a `Decodable` type.
    public func env<T: Decodable>(as type: T.Type) throws -> T { try JSON.object(env).decode(type) }

    public func ok<T: Encodable>(_ data: T, cta: CtaBlock? = nil) throws -> Response { try .value(data, cta: cta) }

    public func error(code: String, message: String, cta: CtaBlock? = nil, exitCode: Int32? = nil,
                      retryable: Bool? = nil) -> Response {
        .error(code: code, message: message, cta: cta, exitCode: exitCode, retryable: retryable)
    }
}

/// Context passed to middleware.
public final class MiddlewareContext: @unchecked Sendable {
    public let agent: Bool
    /// The resolved command path, e.g. `users list`.
    public let command: String
    public let displayName: String
    public let env: JSONObject
    public let format: Format
    public let formatExplicit: Bool
    public let globals: JSONObject
    public let name: String
    public let version: String?
    public let vars: Vars
    var failure: Response?

    init(agent: Bool, command: String, displayName: String, env: JSONObject, format: Format, formatExplicit: Bool,
         globals: JSONObject, name: String, version: String?, vars: Vars) {
        self.agent = agent
        self.command = command
        self.displayName = displayName
        self.env = env
        self.format = format
        self.formatExplicit = formatExplicit
        self.globals = globals
        self.name = name
        self.version = version
        self.vars = vars
    }

    public func set(_ key: String, _ value: Any) { vars.set(key, value) }

    /// Stops with an error. Return without calling `next()` afterwards.
    public func error(code: String, message: String, cta: CtaBlock? = nil, exitCode: Int32? = nil, retryable: Bool? = nil) {
        failure = .error(code: code, message: message, cta: cta, exitCode: exitCode, retryable: retryable)
    }
}

/// Runs around a command. Call `next()` to continue.
public typealias Middleware = @Sendable (MiddlewareContext, @Sendable () async throws -> Void) async throws -> Void

/// A command definition.
public struct Command: @unchecked Sendable {
    public var description: String?
    public var aliases: [String]
    public var args: Shape?
    public var options: Shape?
    public var env: Shape?
    /// Option name to single-character alias.
    public var alias: [String: String]
    public var output: Schema?
    public var examples: [Example]
    public var usage: [Usage]
    public var hint: String?
    public var format: Format?
    public var outputPolicy: OutputPolicy?
    public var destructive: Bool
    public var mcp: ToolExposure?
    public var middleware: [Middleware]
    public var run: @Sendable (Context) async throws -> Response

    public init(
        description: String? = nil, aliases: [String] = [], args: Shape? = nil, options: Shape? = nil, env: Shape? = nil,
        alias: [String: String] = [:], output: Schema? = nil, examples: [Example] = [], usage: [Usage] = [],
        hint: String? = nil, format: Format? = nil, outputPolicy: OutputPolicy? = nil, destructive: Bool = false,
        mcp: ToolExposure? = nil, middleware: [Middleware] = [],
        run: @escaping @Sendable (Context) async throws -> Response
    ) {
        self.description = description
        self.aliases = aliases
        self.args = args
        self.options = options
        self.env = env
        self.alias = alias
        self.output = output
        self.examples = examples
        self.usage = usage
        self.hint = hint
        self.format = format
        self.outputPolicy = outputPolicy
        self.destructive = destructive
        self.mcp = mcp
        self.middleware = middleware
        self.run = run
    }

    /// A command whose handler returns any `Encodable` value.
    public init<T: Encodable>(
        description: String? = nil, aliases: [String] = [], args: Shape? = nil, options: Shape? = nil, env: Shape? = nil,
        alias: [String: String] = [:], output: Schema? = nil, examples: [Example] = [], usage: [Usage] = [],
        hint: String? = nil, format: Format? = nil, outputPolicy: OutputPolicy? = nil, destructive: Bool = false,
        mcp: ToolExposure? = nil, middleware: [Middleware] = [],
        run: @escaping @Sendable (Context) async throws -> T
    ) {
        self.init(description: description, aliases: aliases, args: args, options: options, env: env, alias: alias,
                  output: output, examples: examples, usage: usage, hint: hint, format: format,
                  outputPolicy: outputPolicy, destructive: destructive, mcp: mcp, middleware: middleware) { context in
            try .value(try await run(context))
        }
    }

    var isDestructive: Bool {
        destructive || mcp?.annotations?.destructiveHint == true
    }
}
