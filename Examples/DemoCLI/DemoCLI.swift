import Foundation
import Swiftcur

/// The same CLI as Tests/SwiftcurTests/Fixtures/demo.ts, so outputs can be compared with incur.
public func makeDemoCLI(environment: [String: String]) -> CLI {

    let users = CLI("users", description: "Manage users")
        .command("list", Command(
            description: "List users",
            options: ["limit": .number.default(10).describe("Max users")],
            output: .object(["users": .array(.object(["id": .number, "name": .string]))]),
            mcp: .annotations(ToolAnnotations(readOnlyHint: true))
        ) { context in
            let all: [JSON] = [["id": 1, "name": "Alice"], ["id": 2, "name": "Bob"], ["id": 3, "name": "Carol"]]
            let limit = context.options["limit"]?.intValue ?? 10
            return .ok(["users": .array(Array(all.prefix(limit)))])
        })
        .command("get", Command(
            description: "Get a user",
            args: ["id": .number.describe("User ID")]
        ) { context in
            guard context.args["id"]?.intValue == 1 else {
                return .error(code: "NOT_FOUND", message: "No user \(context.args["id"]!.description)", cta: ["users list"])
            }
            return .ok(["id": 1, "name": "Alice"])
        })
        .command("delete", Command(
            description: "Delete a user",
            args: ["id": .number],
            destructive: true
        ) { context in
            .ok(["deleted": context.args["id"]!])
        })

    let cli = CLI(
        "demo",
        description: "Demo CLI",
        version: "1.2.3",
        env: ["DEMO_TOKEN": .string.optional().describe("API token")],
        globals: ["debug": .boolean.default(false).describe("Verbose output")],
        globalAlias: ["debug": "v"],
        config: ConfigOptions(flag: "config", files: ["demo.json"]),
        banner: Banner(mode: .human) { "DEMO BANNER" },
        sync: SyncOptions(body: "Run demo whoami to check setup.", suggestions: ["list my users"]),
        mcp: McpOptions(
            instructions: "Use demo tools.",
            tools: environment["DEMO_DIRECT"] == nil ? nil : ToolFilter(discovery: .direct)
        ),
        vars: ["user": "none"]
    )
    .use { context, next in
        if context.command == "guarded", context.env["DEMO_TOKEN"] == nil {
            return context.error(code: "AUTH", message: "token required", cta: ["whoami"])
        }
        context.set("user", "mw")
        try await next()
    }
    .command("greet", Command(
        description: "Greet someone",
        aliases: ["hi"],
        args: ["name": .string.describe("Name to greet")],
        options: [
            "loud": .boolean.default(false).describe("Shout"),
            "times": .number.default(1).describe("Repeat count"),
            "style": .choice("plain", "fancy").optional().describe("Style"),
            "old": .string.optional().describe("Old flag").deprecated(),
            "tag": .array(.string).default([]).describe("Tags"),
        ],
        alias: ["loud": "l", "times": "t"],
        output: .object(["message": .string]),
        examples: [
            Example(args: [("name", "world")], description: "Greet the world"),
            Example(args: [("name", "bob")], options: [("loud", true)]),
        ],
        hint: "Names are case-sensitive."
    ) { context in
        let name = context.args["name"]!.stringValue!
        var message = String(repeating: "hello \(name)", count: context.options["times"]?.intValue ?? 1)
        if context.options["loud"] == true { message = message.uppercased() }
        return .ok(["message": .string(message)], cta: [
            "users list",
            Cta("greet", description: "greet again", args: [("name", true)]),
        ])
    })
    .command(users)
    .command("stream", Command(description: "Stream steps") { _ in
        .stream { emitter in
            try await emitter.emit(["step": 1] as JSON)
            try await emitter.emit(["step": 2] as JSON)
            return nil
        }
    })
    .command("fail", Command(description: "Always fails") { _ -> Response in
        throw Boom()
    })
    .command("whoami", Command(
        description: "Show env and globals",
        env: ["DEMO_USER": .string.default("anon").describe("User name")]
    ) { context in
        .ok(["user": context.env["DEMO_USER"]!, "debug": context.globals["debug"] ?? false, "agent": .bool(context.agent)])
    })
    .command("tags", Command(
        description: "Echo tags",
        args: ["first": .string, "rest": .array(.string).optional()],
        options: ["v": Schema.count.describe("Verbosity")]
    ) { context in
        .ok(["first": context.args["first"]!, "rest": context.args["rest"] ?? [], "v": context.options["v"]!])
    })
    .command(environment["DEMO_EXTRA"] == nil ? "text2" : "extra", Command(description: "Extra") { _ in .ok(1) })
    .command("text", Command(description: "Returns text") { _ in .ok("plain text") })
    .command("quiet", Command(description: "Agent-only output", outputPolicy: .agentOnly) { _ in .ok(["secret": 42]) })
    .command("guarded", Command(description: "Needs a token") { context in
        .ok(["user": .string(context.vars.get("user", as: String.self) ?? "")])
    })
    .command("exit42", Command(description: "Custom exit") { context in
        context.error(code: "CUSTOM", message: "custom failure", exitCode: 42, retryable: true)
    })
    .command(CLI("ping", description: "Ping", root: Command { _ in .ok(["pong": true]) }))
    .command(CLI("admin", description: "Admin tools", outputPolicy: .agentOnly)
        .command("stats", Command(description: "Show stats") { _ in .ok(["count": 3]) }))
    .command("fmt", Command(description: "Defaults to JSON", format: .json) { _ in .ok(["a": 1]) })
    .command("port", Command(description: "Needs a port", env: ["DEMO_PORT": .number.describe("Port number")]) { context in
        .ok(["port": context.env["DEMO_PORT"]!])
    })
    .command("usage", Command(
        description: "Custom usage",
        args: ["file": .string.optional()],
        options: ["stdin": .boolean.default(false)],
        usage: [Usage(args: ["file"]), Usage(prefix: "cat x |", options: ["stdin"], suffix: "# from stdin")]
    ) { context in
        .ok(["file": context.args["file"] ?? nil, "stdin": context.options["stdin"]!])
    })
    .command("page", Command(description: "Pages", options: ["page": .int.min(1).default(1).describe("Page")]) { context in
        .ok(["page": context.options["page"]!])
    })

    return cli
}

struct Boom: Error, CustomStringConvertible {
    var description: String { "boom" }
}
