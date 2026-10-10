import Foundation

/// Coding agents that read skills from disk.
struct Agent {
    var name: String
    var globalSkillsDir: String
    var projectSkillsDir: String
    /// Universal agents read `~/.agents/skills` directly; others get a symlink.
    var universal: Bool
    var marker: String

    var isInstalled: Bool { FileManager.default.fileExists(atPath: marker) }

    static func all(_ environment: [String: String]) -> [Agent] {
        let home = environment["HOME"] ?? NSHomeDirectory()
        let config = nonEmpty(environment["XDG_CONFIG_HOME"]) ?? "\(home)/.config"
        let claude = nonEmpty(environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespaces)) ?? "\(home)/.claude"
        let codex = nonEmpty(environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespaces)) ?? "\(home)/.codex"
        func agent(_ name: String, _ global: String, _ project: String, _ universal: Bool, _ marker: String) -> Agent {
            Agent(name: name, globalSkillsDir: global, projectSkillsDir: project, universal: universal, marker: marker)
        }
        return [
            agent("Amp", "\(config)/agents/skills", ".agents/skills", true, "\(config)/amp"),
            agent("Cline", "\(home)/.agents/skills", ".agents/skills", true, "\(home)/.cline"),
            agent("Codex", "\(codex)/skills", ".agents/skills", true, codex),
            agent("Cursor", "\(home)/.cursor/skills", ".agents/skills", true, "\(home)/.cursor"),
            agent("Gemini CLI", "\(home)/.gemini/skills", ".agents/skills", true, "\(home)/.gemini"),
            agent("GitHub Copilot", "\(home)/.copilot/skills", ".agents/skills", true, "\(home)/.copilot"),
            agent("Kimi CLI", "\(config)/agents/skills", ".agents/skills", true, "\(home)/.kimi"),
            agent("OpenCode", "\(config)/opencode/skills", ".agents/skills", true, "\(config)/opencode"),
            agent("Claude Code", "\(claude)/skills", ".claude/skills", false, claude),
            agent("Windsurf", "\(home)/.codeium/windsurf/skills", ".windsurf/skills", false, "\(home)/.codeium/windsurf"),
            agent("Continue", "\(home)/.continue/skills", ".continue/skills", false, "\(home)/.continue"),
            agent("Roo", "\(home)/.roo/skills", ".roo/skills", false, "\(home)/.roo"),
            agent("Kilo", "\(home)/.kilocode/skills", ".kilocode/skills", false, "\(home)/.kilocode"),
            agent("Goose", "\(config)/goose/skills", ".goose/skills", false, "\(config)/goose"),
            agent("Augment", "\(home)/.augment/skills", ".augment/skills", false, "\(home)/.augment"),
            agent("Trae", "\(home)/.trae/skills", ".trae/skills", false, "\(home)/.trae"),
            agent("Junie", "\(home)/.junie/skills", ".junie/skills", false, "\(home)/.junie"),
            agent("Crush", "\(config)/crush/skills", ".crush/skills", false, "\(config)/crush"),
            agent("Kiro CLI", "\(home)/.kiro/skills", ".kiro/skills", false, "\(home)/.kiro"),
            agent("Qwen Code", "\(home)/.qwen/skills", ".qwen/skills", false, "\(home)/.qwen"),
            agent("OpenHands", "\(home)/.openhands/skills", ".openhands/skills", false, "\(home)/.openhands"),
        ]
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

/// Installs, lists, and removes generated skills.
struct SkillInstaller {
    struct Installed {
        var agent: String
        var path: String
        var mode: String
    }

    let environment: [String: String]
    var home: String { environment["HOME"] ?? NSHomeDirectory() }
    private let files = FileManager.default

    /// Copies each `<name>/SKILL.md` under `source` to `.agents/skills`, then links it for non-universal agents.
    func install(from source: String, global: Bool, cwd: String) -> (paths: [String], agents: [Installed]) {
        let base = global ? home : cwd
        let canonicalBase = "\(base)/.agents/skills"
        let detected = Agent.all(environment).filter(\.isInstalled)
        var paths: [String] = []
        var agents: [Installed] = []

        for skill in discover(source) {
            let canonical = "\(canonicalBase)/\(skill.name)"
            remove(canonical)
            try? files.createDirectory(atPath: canonical, withIntermediateDirectories: true)
            if skill.isRoot {
                try? files.copyItem(atPath: "\(skill.dir)/SKILL.md", toPath: "\(canonical)/SKILL.md")
            } else {
                for item in (try? files.contentsOfDirectory(atPath: skill.dir)) ?? [] {
                    try? files.copyItem(atPath: "\(skill.dir)/\(item)", toPath: "\(canonical)/\(item)")
                }
            }
            paths.append(canonical)

            for agent in detected where !agent.universal {
                let skillsDir = global ? agent.globalSkillsDir : "\(cwd)/\(agent.projectSkillsDir)"
                let target = "\(skillsDir)/\(skill.name)"
                if realParent(target) == realParent(canonical) { continue }
                remove(target)
                try? files.createDirectory(atPath: skillsDir, withIntermediateDirectories: true)
                let relative = relativePath(from: realParent(skillsDir), to: realParent(canonical))
                if (try? files.createSymbolicLink(atPath: target, withDestinationPath: relative)) != nil {
                    agents.append(Installed(agent: agent.name, path: target, mode: "symlink"))
                } else if (try? files.copyItem(atPath: canonical, toPath: target)) != nil {
                    agents.append(Installed(agent: agent.name, path: target, mode: "copy"))
                }
            }
        }
        return (paths, agents)
    }

    func uninstall(_ skill: String, global: Bool, cwd: String) {
        let base = global ? home : cwd
        remove("\(base)/.agents/skills/\(skill)")
        for agent in Agent.all(environment).filter(\.isInstalled) where !agent.universal {
            remove("\(global ? agent.globalSkillsDir : "\(cwd)/\(agent.projectSkillsDir)")/\(skill)")
        }
    }

    private func discover(_ root: String) -> [(name: String, dir: String, isRoot: Bool)] {
        var results: [(name: String, dir: String, isRoot: Bool)] = []
        func visit(_ dir: String) {
            for entry in ((try? files.contentsOfDirectory(atPath: dir)) ?? []).sorted() {
                let path = "\(dir)/\(entry)"
                var isDirectory: ObjCBool = false
                guard files.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                if let content = try? String(contentsOfFile: "\(path)/SKILL.md", encoding: .utf8) {
                    results.append((sanitize(SkillFile.frontmatter(content).name ?? entry), path, false))
                }
                visit(path)
            }
        }
        visit(root)
        if let content = try? String(contentsOfFile: "\(root)/SKILL.md", encoding: .utf8) {
            let name = sanitize(SkillFile.frontmatter(content).name ?? "skill")
            if !results.contains(where: { $0.name == name }) { results.append((name, root, true)) }
        }
        return results
    }

    private func sanitize(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-").replacingOccurrences(of: "..", with: "").prefix(255))
    }

    private func remove(_ path: String) {
        if (try? files.destinationOfSymbolicLink(atPath: path)) != nil || files.fileExists(atPath: path) {
            try? files.removeItem(atPath: path)
        }
    }

    /// Resolves symlinks in the parent directory, keeping the last component.
    private func realParent(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        return "\(parent)/\(url.lastPathComponent)"
    }

    private func relativePath(from base: String, to target: String) -> String {
        let from = base.split(separator: "/"), to = target.split(separator: "/")
        var common = 0
        while common < min(from.count, to.count), from[common] == to[common] { common += 1 }
        return (Array(repeating: "..", count: from.count - common) + to[common...].map(String.init)).joined(separator: "/")
    }
}

/// Remembers what `skills add` installed, for stale detection and cleanup.
struct SkillMeta: Codable {
    var hash: String
    var skills: [String]?
    var paths: [String]?
    var at: String?

    static func path(_ name: String, _ environment: [String: String]) -> String {
        let home = environment["HOME"] ?? NSHomeDirectory()
        let data = (environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 }) ?? "\(home)/.local/share"
        return "\(data)/swiftcur/\(name).json"
    }

    static func read(_ name: String, _ environment: [String: String]) -> SkillMeta? {
        guard let data = FileManager.default.contents(atPath: path(name, environment)) else { return nil }
        return try? JSONDecoder().decode(SkillMeta.self, from: data)
    }

    func write(_ name: String, _ environment: [String: String]) {
        let file = Self.path(name, environment)
        try? FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) { FileManager.default.createFile(atPath: file, contents: data + Data("\n".utf8)) }
    }

    /// Names of synced skills still on disk.
    static func installed(_ name: String, _ environment: [String: String], cwd: String) -> Set<String> {
        guard let meta = read(name, environment), let skills = meta.skills, !skills.isEmpty else { return [] }
        let exists = { (dir: String) in FileManager.default.fileExists(atPath: "\(dir)/SKILL.md") }
        if let paths = meta.paths, !paths.isEmpty {
            return Set(paths.filter(exists).map { ($0 as NSString).lastPathComponent })
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        let bases = ["\(home)/.agents/skills", "\(cwd)/.agents/skills"]
        return Set(skills.filter { skill in bases.contains { exists("\($0)/\(skill)") } })
    }
}
