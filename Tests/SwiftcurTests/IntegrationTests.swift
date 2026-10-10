import DemoCLI
import Foundation
@testable import Swiftcur
import XCTest

/// Behavior incur implements through npm or external tools, checked directly.
final class IntegrationTests: XCTestCase {
    private var home: String!

    override func setUp() {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("swiftcur-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: home)
    }

    private func run(_ cli: CLI, _ argv: [String], tty: Bool = false, environment: [String: String] = [:]) async -> (String, Int32) {
        var output = ""
        let io = IO(stdout: { output += $0 }, stderr: { output += $0 }, isTTY: tty,
                    environment: ["HOME": home, "XDG_DATA_HOME": "\(home!)/data", "XDG_CACHE_HOME": "\(home!)/cache"]
                        .merging(environment) { $1 },
                    executable: "/usr/local/bin/\(cli.name)", stdin: { nil })
        let code = await cli.run(argv, io: io)
        return (output, code)
    }

    private func read(_ path: String) -> String {
        (try? String(contentsOfFile: "\(home!)/\(path)", encoding: .utf8)) ?? ""
    }

    // MARK: mcp add

    func testMcpAddWritesAgentConfigs() async throws {
        let manager = FileManager.default
        for dir in [".claude", ".cursor", ".codex", ".config/amp"] {
            try manager.createDirectory(atPath: "\(home!)/\(dir)", withIntermediateDirectories: true)
        }
        try #"{"theme":"dark","mcpServers":{"other":{"command":"x"}}}"#.write(toFile: "\(home!)/.claude.json", atomically: true, encoding: .utf8)
        try "model = \"o3\"\n\n[mcp_servers.demo]\ncommand = \"old\"\n".write(toFile: "\(home!)/.codex/config.toml", atomically: true, encoding: .utf8)

        let (output, code) = await run(makeDemoCLI(environment: [:]), ["mcp", "add", "--json"])
        XCTAssertEqual(code, 0, output)
        XCTAssertTrue(output.contains("✓ Registered demo as MCP server"))
        XCTAssertTrue(output.contains(#""command": "/usr/local/bin/demo --mcp""#), output)

        let claude = try JSONParser.parse(read(".claude.json"))
        XCTAssertEqual(claude["theme"], "dark")
        XCTAssertEqual(claude["mcpServers"]?["other"]?["command"], "x")
        XCTAssertEqual(claude["mcpServers"]?["demo"], ["type": "stdio", "command": "/usr/local/bin/demo", "args": ["--mcp"]])
        XCTAssertEqual(try JSONParser.parse(read(".cursor/mcp.json"))["mcpServers"]?["demo"]?["args"], ["--mcp"])
        XCTAssertEqual(try JSONParser.parse(read(".config/amp/settings.json"))["amp.mcpServers"]?["demo"]?["command"], "/usr/local/bin/demo")
        XCTAssertEqual(read(".codex/config.toml"),
                       "model = \"o3\"\n\n[mcp_servers.demo]\ncommand = \"/usr/local/bin/demo\"\nargs = [\"--mcp\"]\n")
    }

    func testMcpAddTargetsOneAgentWithCustomCommand() async throws {
        let (output, code) = await run(makeDemoCLI(environment: [:]), ["mcp", "add", "--agent", "cursor", "-c", "demo --mcp --debug"])
        XCTAssertEqual(code, 0, output)
        XCTAssertTrue(output.contains("Agents: Cursor"))
        XCTAssertEqual(try JSONParser.parse(read(".cursor/mcp.json"))["mcpServers"]?["demo"], ["command": "demo", "args": ["--mcp", "--debug"]])
    }

    func testMcpAddRejectsUnknownAgent() async {
        let (output, code) = await run(makeDemoCLI(environment: [:]), ["mcp", "add", "--agent", "nope"])
        XCTAssertEqual(code, 1)
        XCTAssertTrue(output.contains("MCP_ADD_FAILED"), output)
    }

    // MARK: skills

    func testSkillsAddToProjectWithInclude() async throws {
        // Hand-written skills live in one place (e.g. an app bundle); the project is the current directory.
        let bundle = "\(home!)/bundle"
        let project = "\(home!)/project"
        try FileManager.default.createDirectory(atPath: "\(bundle)/skills/extra", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        try "---\nname: extra\ndescription: Hand-written.\n---\n\n# Extra\n".write(toFile: "\(bundle)/skills/extra/SKILL.md", atomically: true, encoding: .utf8)
        let cli = CLI("tool", description: "Tool", sync: SyncOptions(cwd: bundle, include: ["skills/*"]))
            .command("ping", Command(description: "Ping") { _ in .ok(true) })

        let previous = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(project)
        defer { FileManager.default.changeCurrentDirectoryPath(previous) }
        let (output, code) = await run(cli, ["skills", "add", "--no-global"])
        XCTAssertEqual(code, 0, output)
        XCTAssertTrue(output.contains("2 skills synced"), output)
        let installed = URL(fileURLWithPath: project).resolvingSymlinksInPath().path + "/.agents/skills"
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(installed)/tool-ping/SKILL.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(installed)/extra/SKILL.md"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(bundle)/.agents"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(home!)/.agents/skills/tool-ping"))
    }

    func testSkillsDisabled() async {
        let cli = CLI("tool", sync: nil).command("ping", Command { _ in .ok(true) })
        let (help, _) = await run(cli, ["--help"])
        XCTAssertFalse(help.contains("skills"))
        let (output, code) = await run(cli, ["skills", "add"])
        XCTAssertEqual(code, 1)
        XCTAssertTrue(output.contains("COMMAND_NOT_FOUND"))
    }

    // MARK: updates

    func testUpdateNoticeAndInstall() async throws {
        actor Flag { var installed = false; func set() { installed = true } }
        let flag = Flag()
        let cli = CLI("tool", version: "1.0.0", update: UpdateOptions(check: { _ in "1.2.0" }, install: { _ in await flag.set() }))
            .command("ping", Command { _ in .ok("pong") })

        try FileManager.default.createDirectory(atPath: "\(home!)/cache/swiftcur/updates", withIntermediateDirectories: true)
        let now = Date().timeIntervalSince1970 * 1000
        try #"{"checkedAt":\#(now),"latest":"1.2.0"}"#.write(toFile: "\(home!)/cache/swiftcur/updates/tool.json", atomically: true, encoding: .utf8)

        let (output, _) = await run(cli, ["ping"], tty: true)
        XCTAssertEqual(output, "pong\n\nUpdate available for tool:\n  tool --update  # upgrade from 1.0.0 to 1.2.0\n")
        let (quiet, _) = await run(cli, ["ping"], tty: true, environment: ["CI": "1"])
        XCTAssertEqual(quiet, "pong\n")
        let (agent, _) = await run(cli, ["ping"])
        XCTAssertEqual(agent, "pong\n")

        let (updated, code) = await run(cli, ["--update"], tty: true)
        XCTAssertEqual(code, 0)
        XCTAssertEqual(updated, "✓ Updated tool\n")
        let installed = await flag.installed
        XCTAssertTrue(installed)
    }

    func testUpdateWithoutInstaller() async {
        let (output, code) = await run(CLI("tool"), ["--update"])
        XCTAssertEqual(code, 1)
        XCTAssertTrue(output.contains("UPDATE_FAILED"))
    }

    func testVersionComparison() {
        XCTAssertTrue(Updater.isNewer("1.2.0", than: "1.1.9"))
        XCTAssertTrue(Updater.isNewer("1.0.0", than: "1.0.0-beta.2"))
        XCTAssertTrue(Updater.isNewer("1.0.0-beta.10", than: "1.0.0-beta.2"))
        XCTAssertTrue(Updater.isNewer("1.0.0-rc", than: "1.0.0-beta"))
        XCTAssertFalse(Updater.isNewer("1.0.0-beta", than: "1.0.0"))
        XCTAssertFalse(Updater.isNewer("1.0.0", than: "1.0.0"))
        XCTAssertFalse(Updater.isNewer("garbage", than: "1.0.0"))
    }

    // MARK: config

    func testConfigSchema() {
        let schema = makeDemoCLI(environment: [:]).configSchema()
        XCTAssertEqual(schema["properties"]?["$schema"], ["type": "string"])
        XCTAssertEqual(schema["properties"]?["commands"]?["properties"]?["greet"]?["properties"]?["options"]?["properties"]?["times"],
                       ["default": 1, "description": "Repeat count", "type": "number"])
        XCTAssertNotNil(schema["properties"]?["commands"]?["properties"]?["users"]?["properties"]?["commands"]?["properties"]?["list"])
    }

    func testCustomConfigLoader() async {
        let cli = CLI("tool", config: ConfigOptions(loader: { _ in ["commands": ["echo": ["options": ["word": "from-loader"]]]] }))
            .command("echo", Command(options: ["word": .string.default("default")]) { context in .ok(context.options["word"]!) })
        let (output, _) = await run(cli, ["echo"])
        XCTAssertEqual(output, "from-loader\n")
        let (override, _) = await run(cli, ["echo", "--word", "argv"])
        XCTAssertEqual(override, "argv\n")
    }

    // MARK: Codable handlers

    func testEncodableHandlersAndDecodedInput() async {
        struct Input: Decodable { let name: String; let count: Double }
        struct Reply: Encodable { let greeting: String; let repeated: Int }
        let cli = CLI("tool").command("hi", Command(
            args: ["name": .string], options: ["count": .number.default(2)]
        ) { context -> Reply in
            let input = try context.args(as: Input.self, options: true)
            return Reply(greeting: "hi \(input.name)", repeated: Int(input.count))
        })
        let (output, code) = await run(cli, ["hi", "ann", "--json"])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(output, "{\n  \"greeting\": \"hi ann\",\n  \"repeated\": 2\n}\n")
    }

    // MARK: completions

    func testBashCompletionScriptAndCandidates() async {
        let cli = makeDemoCLI(environment: [:])
        let (script, _) = await run(cli, ["completions", "bash"])
        XCTAssertTrue(script.contains("complete -o default -o bashdefault -o nosort -F _swiftcur_complete_demo demo"))
        let (candidates, _) = await run(cli, ["--", "demo", "us"], environment: ["COMPLETE": "bash", "_COMPLETE_INDEX": "1"])
        XCTAssertEqual(candidates, "users\u{01}\u{0B}usage")
    }
}

extension IntegrationTests {
    func testMcpAddResolvesBareNameThroughPath() async throws {
        let bin = "\(home!)/bin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "\(bin)/real-tool", contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        try FileManager.default.createSymbolicLink(atPath: "\(bin)/tool", withDestinationPath: "\(bin)/real-tool")
        let cli = CLI("tool").command("ping", Command { _ in .ok(true) })
        var output = ""
        let io = IO(stdout: { output += $0 }, stderr: { output += $0 }, isTTY: false,
                    environment: ["HOME": home, "PATH": "/nonexistent:\(bin)"], executable: "tool", stdin: { nil })
        let code = await cli.run(["mcp", "add", "--agent", "cursor", "--json"], io: io)
        XCTAssertEqual(code, 0, output)
        let real = URL(fileURLWithPath: "\(bin)/real-tool").resolvingSymlinksInPath().path
        XCTAssertEqual(try JSONParser.parse(read(".cursor/mcp.json"))["mcpServers"]?["tool"]?["command"], .string(real))
    }
}
