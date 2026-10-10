import Foundation
@testable import Swiftcur
import XCTest

/// The README's code samples, compiled and run.
final class ReadmeTests: XCTestCase {
    private func run(_ cli: CLI, _ argv: [String], tty: Bool = false, environment: [String: String] = [:]) async -> String {
        var output = ""
        let io = IO(stdout: { output += $0 }, stderr: { output += $0 }, isTTY: tty, environment: environment,
                    executable: cli.name, stdin: { nil })
        _ = await cli.run(argv, io: io)
        return output
    }

    func testQuickStart() async {
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
        let loud = await run(cli, ["hello", "world", "-l"])
        XCTAssertEqual(loud, "message: HELLO WORLD\n")
        let json = await run(cli, ["hello", "world", "--json"])
        XCTAssertEqual(json, "{\n  \"message\": \"hello world\"\n}\n")
        let missing = await run(cli, ["hello"], tty: true)
        XCTAssertTrue(missing.hasPrefix("Error: missing required argument <name>\nSee below for usage.\n"), missing)
    }

    func testArgumentsAndOptions() async {
        let cli = CLI("cp").command("copy", Command(
            args: [
                "source": .string.describe("File to copy"),
                "count": .int.coerce().optional(),
                "targets": .array(.string).optional(),
            ],
            options: [
                "force": .boolean.default(false),
                "retries": .int.min(0).max(5).default(3),
                "mode": .choice("fast", "safe").optional(),
                "tag": .array(.string).default([]),
                "verbose": Schema.count,
                "legacy": .string.optional().deprecated(),
            ],
            alias: ["force": "f", "verbose": "v"]
        ) { context in .ok(.object(context.args.merging(context.options))) })
        let output = await run(cli, ["copy", "a", "3", "b", "c", "-fvv", "--retries=2", "--tag", "x", "--tag", "y", "--json"])
        XCTAssertEqual(try JSONParser.parse(output), [
            "source": "a", "count": 3, "targets": ["b", "c"], "force": true, "retries": 2, "tag": ["x", "y"], "verbose": 2,
        ])
    }

    func testTypedInputAndOutput() async {
        struct Input: Decodable { let name: String; let loud: Bool }
        struct Reply: Encodable { let message: String }
        let cli = CLI("t").command("hi", Command(args: ["name": .string], options: ["loud": .boolean.default(false)]) { context -> Reply in
            let input = try context.args(as: Input.self, options: true)
            return Reply(message: input.loud ? input.name.uppercased() : input.name)
        })
        let output = await run(cli, ["hi", "ann", "--loud"])
        XCTAssertEqual(output, "message: ANN\n")
    }

    func testEnvAndGlobals() async {
        let cli = CLI("deploy",
                      env: ["API_TOKEN": .string.describe("API token")],
                      globals: ["region": .string.default("us-east").describe("Region")],
                      globalAlias: ["region": "r"])
            .command("go", Command(env: ["DEPLOY_KEY": .string.optional()]) { context in
                .ok(["key": context.env["DEPLOY_KEY"] ?? nil, "region": context.globals["region"]!])
            })
        let output = await run(cli, ["go", "-r", "eu"], environment: ["API_TOKEN": "t", "DEPLOY_KEY": "k"])
        XCTAssertEqual(output, "key: k\nregion: eu\n")
    }

    func testGroups() async {
        let users = CLI("users", description: "Manage users")
            .command("list", Command { _ in .ok([]) })
            .command("get", Command(args: ["id": .int.coerce()]) { context in .ok(context.args["id"]!) })
        let cli = CLI("app").command(users)
        let output = await run(cli, ["users", "get", "3"])
        XCTAssertEqual(output, "3\n")
    }

    func testResultsAndErrors() async {
        let cli = CLI("app")
            .command("ok", Command { _ in
                .ok(["n": 1], cta: ["users list", Cta("users get", description: "inspect one", args: [("id", true)])])
            })
            .command("missing", Command { _ in .error(code: "NOT_FOUND", message: "No user 7", cta: ["users list"], exitCode: 4, retryable: false) })
            .command("limited", Command { _ -> Response in throw CommandError(code: "RATE_LIMITED", message: "Try again later", retryable: true) })
        let ok = await run(cli, ["ok"], tty: true)
        XCTAssertEqual(ok, "n: 1\n\nSuggested commands:\n  app users list\n  app users get <id>  # inspect one\n")
        var code: Int32 = 0
        let io = IO(stdout: { _ in }, stderr: { _ in }, isTTY: false, environment: [:], executable: "app")
        code = await cli.run(["missing"], io: io)
        XCTAssertEqual(code, 4)
        let limited = await run(cli, ["limited", "--json"])
        XCTAssertEqual(try JSONParser.parse(limited), ["code": "RATE_LIMITED", "message": "Try again later", "retryable": true])
    }

    func testStreaming() async {
        let cli = CLI("app").command("logs", Command(description: "Tail logs") { _ in
            .stream { emitter in
                try await emitter.emit(["line": "starting"] as JSON)
                try await emitter.emit(["line": "done"] as JSON)
                return .ok(cta: ["status"])
            }
        })
        let output = await run(cli, ["logs", "--format", "jsonl"])
        let lines = output.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(String(lines[0]), #"{"type":"chunk","data":{"line":"starting"}}"#)
        XCTAssertTrue(lines[2].contains(#""cta":{"description":"Suggested command:","commands":[{"command":"app status"}]}"#))
    }

    func testMiddleware() async {
        let cli = CLI("app", env: ["API_TOKEN": .string.optional()])
            .use { context, next in
                guard context.env["API_TOKEN"] != nil else {
                    return context.error(code: "AUTH", message: "Set API_TOKEN", cta: ["login"])
                }
                context.set("user", "ann")
                try await next()
            }
            .command("me", Command { context in .ok(["user": .string(context.vars.get("user", as: String.self) ?? "")]) })
        let denied = await run(cli, ["me"])
        XCTAssertTrue(denied.hasPrefix("code: AUTH\nmessage: Set API_TOKEN\n"), denied)
        let allowed = await run(cli, ["me"], environment: ["API_TOKEN": "x"])
        XCTAssertEqual(allowed, "user: ann\n")
    }

    func testMcpExposureCompiles() {
        _ = Command(mcp: .hidden) { _ in .ok() }
        _ = Command(mcp: .tool(name: "x", description: "d", annotations: ToolAnnotations(readOnlyHint: true), instructions: "i")) { _ in .ok() }
        _ = McpOptions(tools: ToolFilter(discovery: .direct, include: ["users_*"], exclude: ["users_delete"]))
        _ = ConfigOptions(flag: "config", files: ["deploy.json", "~/.config/deploy/config.json"])
    }
}
