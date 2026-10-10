import DemoCLI
import Foundation
@testable import Swiftcur
import XCTest

/// Runs the demo CLI in-process against outputs recorded from real incur (see scripts/record-incur.sh).
/// `@sh` cases need a real shell and run only in scripts/compare.sh.
final class IncurParityTests: XCTestCase {
    private var fixtures: URL { Bundle.module.resourceURL!.appendingPathComponent("Fixtures") }

    func testCases1() async throws { try await runCases("cases1") }
    func testCases2() async throws { try await runCases("cases2") }
    func testCases3() async throws { try await runCases("cases3") }
    func testCases4() async throws { try await runCases("cases4") }

    private func runCases(_ file: String) async throws {
        let text = try String(contentsOf: fixtures.appendingPathComponent("cases/\(file).txt"), encoding: .utf8)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("tmp.\(UUID().uuidString.prefix(8))").path
        try FileManager.default.createDirectory(atPath: "\(work)/home", withIntermediateDirectories: true)
        try #"{ "commands": { "greet": { "options": { "times": 2, "loud": true } } } }"#.write(toFile: "\(work)/demo.json", atomically: true, encoding: .utf8)
        try #"{ "commands": { "greet": { "options": { "times": 3 } } } }"#.write(toFile: "\(work)/other.json", atomically: true, encoding: .utf8)
        let previous = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(work)
        defer {
            FileManager.default.changeCurrentDirectoryPath(previous)
            try? FileManager.default.removeItem(atPath: work)
        }

        var checked = 0
        for line in text.split(separator: "\n") where !line.isEmpty {
            let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
            let (name, spec) = (parts[0], parts.count > 1 ? parts[1] : "")
            if spec.hasPrefix("@sh") { continue }
            let actual = await run(spec, work: work)
            let expected = try String(contentsOf: fixtures.appendingPathComponent("incur/\(name).txt"), encoding: .utf8)
            let post: (String) -> String = spec.hasPrefix("@stdin:") ? Self.sortJsonRpc : { $0 }
            XCTAssertEqual(post(normalize(actual, work)), post(normalize(expected, work)), "\(name): \(spec)")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0)
    }

    private func run(_ spec: String, work: String) async -> String {
        var spec = spec
        var isTTY = false
        var stdinFile: String?
        if spec.hasPrefix("@tty") {
            isTTY = true
            spec = String(spec.dropFirst(4))
        } else if spec.hasPrefix("@stdin:") {
            let rest = spec.dropFirst(7)
            let file = rest.prefix { $0 != " " }
            stdinFile = String(file)
            spec = String(rest.dropFirst(file.count))
        }
        var environment = ["HOME": "\(work)/home", "XDG_DATA_HOME": "\(work)/home/.local/share", "PATH": "/usr/bin:/bin"]
        var argv = Self.shellWords(spec)
        // Leading NAME=value words are environment assignments; a BIN marker separates them from argv.
        while let first = argv.first, first.contains("="), !first.hasPrefix("-") {
            let pair = first.split(separator: "=", maxSplits: 1).map(String.init)
            environment[pair[0]] = pair.count > 1 ? pair[1] : ""
            argv.removeFirst()
        }
        if argv.first == "BIN" { argv.removeFirst() }

        var output = ""
        var lines = stdinFile.flatMap { try? String(contentsOf: fixtures.appendingPathComponent("stdin/\($0)"), encoding: .utf8) }?
            .split(separator: "\n").map(String.init) ?? []
        let io = IO(stdout: { output += $0 }, stderr: { output += $0 }, isTTY: isTTY, environment: environment,
                    executable: "\(work)/demo", stdin: { lines.isEmpty ? nil : lines.removeFirst() })
        let code = await makeDemoCLI(environment: environment).run(argv, io: io)
        return output + "exit=\(code)\n"
    }

    private func normalize(_ text: String, _ work: String) -> String {
        var result = text.replacingOccurrences(of: #"[0-9]+ms"#, with: "Nms", options: .regularExpression)
        result = result.replacingOccurrences(of: #"/(private/)?var/folders/[^ "]*/T/tmp\.[A-Za-z0-9-]+"#, with: "WORK", options: .regularExpression)
        result = result.replacingOccurrences(of: "_swiftcur_complete_", with: "_incur_complete_")
        return result.hasSuffix("\n") ? result : result + "\n"
    }

    /// JSON-RPC responses can arrive in any order; compare them sorted by id with sorted keys.
    private static func sortJsonRpc(_ text: String) -> String {
        var messages: [(String, String)] = []
        var tail: [String] = []
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
                tail.append(String(line))
                continue
            }
            messages.append(("\(object["id"] ?? "")", String(decoding: canonical, as: UTF8.self)))
        }
        let sorted = messages.sorted { (Int($0.0) ?? -1, $0.1) < (Int($1.0) ?? -1, $1.1) }.map(\.1)
        return (sorted + tail).joined(separator: "\n")
    }

    /// Splits like a POSIX shell for the quoting the case files use.
    static func shellWords(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        for character in text {
            if let active = quote {
                if character == active { quote = nil } else { current.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
                inWord = true
            } else if character == " " {
                if inWord { words.append(current) }
                current = ""
                inWord = false
            } else {
                current.append(character)
                inWord = true
            }
        }
        if inWord { words.append(current) }
        return words
    }
}
