import Foundation

/// Loads option defaults from a JSON config file shaped like the command tree:
/// `{ "options": {…}, "commands": { "list": { "options": {…} } } }`.
struct ConfigLoader {
    let cli: CLI
    let io: IO

    func defaults(for path: String, flags: BuiltinFlags) async throws -> JSONObject? {
        guard let config = cli.config, !flags.configDisabled else { return nil }
        let target: String?
        if let explicit = flags.configPath {
            target = resolve(explicit)
        } else {
            target = (config.files ?? ["\(cli.name).json"]).map(resolve).first { FileManager.default.isReadableFile(atPath: $0) }
        }

        let parsed: JSONObject
        if let loader = config.loader {
            guard let result = try await loader(target) else { return nil }
            parsed = result
        } else {
            guard let target, let result = try read(target, explicit: flags.configPath != nil) else { return nil }
            parsed = result
        }
        return try section(parsed, path: path)
    }

    private func resolve(_ path: String) -> String {
        let home = io.environment["HOME"] ?? NSHomeDirectory()
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst() }
        if path.hasPrefix("/") { return path }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(path).standardizedFileURL.path
    }

    private func read(_ path: String, explicit: Bool) throws -> JSONObject? {
        guard let data = FileManager.default.contents(atPath: path) else {
            if explicit { throw ParseError("Config file not found: \(path)") }
            return nil
        }
        let value: JSON
        do {
            value = try JSONParser.parse(String(decoding: data, as: UTF8.self))
        } catch {
            throw ParseError("Invalid JSON config file: \(path)\n\nDetails: \(error)")
        }
        guard let object = value.objectValue else {
            throw ParseError("Invalid config file: expected a top-level object in \(path)")
        }
        return object
    }

    private func section(_ parsed: JSONObject, path: String) throws -> JSONObject? {
        let segments = path == cli.name ? [] : path.split(separator: " ").map(String.init)
        var node: JSON = .object(parsed)
        for segment in segments {
            guard let commands = node["commands"]?.objectValue, let next = commands[segment] else { return nil }
            node = next
        }
        guard node.objectValue != nil else { throw ParseError("Invalid config section for '\(path)': expected an object") }
        guard let options = node["options"] else { return nil }
        guard let object = options.objectValue else { throw ParseError("Invalid config 'options' for '\(path)': expected an object") }
        return object.isEmpty ? nil : object
    }
}

extension CLI {
    /// JSON Schema describing this CLI's config file, for editor autocomplete.
    public func configSchema() -> JSON {
        var node = Self.configNode(commands, root?.options)
        var properties = node["properties"]?.objectValue ?? JSONObject()
        properties["$schema"] = ["type": "string"]
        node["properties"] = .object(properties)
        return .object(node)
    }

    private static func configNode(_ commands: Commands, _ options: Shape?) -> JSONObject {
        var properties = JSONObject()
        if let options, !options.isEmpty {
            let schema = Schema.objectSchema(options)
            properties["options"] = ["type": "object", "additionalProperties": false, "properties": schema["properties"] ?? [:]]
        }
        var commandProperties = JSONObject()
        for (name, entry) in commands.canonical {
            switch entry {
            case .command(let command): commandProperties[name] = .object(configNode(Commands(), command.options))
            case .group(let group): commandProperties[name] = .object(configNode(group.commands, group.root?.options))
            case .alias: break
            }
        }
        if !commandProperties.isEmpty {
            properties["commands"] = ["type": "object", "additionalProperties": false, "properties": .object(commandProperties)]
        }
        var node: JSONObject = ["type": "object", "additionalProperties": false]
        if !properties.isEmpty { node["properties"] = .object(properties) }
        return node
    }
}

/// Update notices and `--update`.
struct Updater {
    let cli: CLI
    let io: IO

    private struct Cache: Codable {
        var checkedAt: Double
        var latest: String?
    }

    private var cacheFile: String {
        let home = io.environment["HOME"] ?? NSHomeDirectory()
        let root = io.environment["XDG_CACHE_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.cache"
        let key = cli.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? cli.name
        return "\(root)/swiftcur/updates/\(key).json"
    }

    private var notificationsDisabled: Bool {
        let environment = io.environment
        if let value = environment["NO_UPDATE_NOTIFIER"], !value.isEmpty { return true }
        if environment["npm_config_update_notifier"] == "false" { return true }
        if let ci = environment["CI"], !ci.isEmpty, ci != "false" { return true }
        return false
    }

    /// Suggests `--update` when a newer version is cached; refreshes the cache in the background when stale.
    func notice(displayName: String) -> FormattedCtaBlock? {
        guard !notificationsDisabled, let update = cli.update, update.check != nil, let current = cli.version else { return nil }
        let cached = readCache()
        let now = Date().timeIntervalSince1970 * 1000
        if cached == nil || now - cached!.checkedAt >= update.interval * 1000 { scheduleRefresh(now, latest: cached?.latest) }
        guard let latest = cached?.latest, Self.isNewer(latest, than: current) else { return nil }
        return FormattedCtaBlock(description: "Update available for \(cli.name):", commands: [
            FormattedCta(command: "\(displayName) --update", description: "upgrade from \(current) to \(latest)"),
        ])
    }

    func refresh() async {
        guard let check = cli.update?.check, let current = cli.version,
              let latest = try? await check(.init(name: cli.name, current: current)), Self.parse(latest) != nil else { return }
        writeCache(Cache(checkedAt: Date().timeIntervalSince1970 * 1000, latest: latest))
    }

    func install() async throws -> String {
        guard let install = cli.update?.install else { throw ParseError("No update installer is configured for '\(cli.name)'.") }
        try await install(.init(name: cli.name, current: cli.version, latest: readCache()?.latest))
        return cli.name
    }

    private func readCache() -> Cache? {
        FileManager.default.contents(atPath: cacheFile).flatMap { try? JSONDecoder().decode(Cache.self, from: $0) }
    }

    private func writeCache(_ cache: Cache) {
        try? FileManager.default.createDirectory(atPath: (cacheFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cache) { FileManager.default.createFile(atPath: cacheFile, contents: data) }
    }

    private func scheduleRefresh(_ now: Double, latest: String?) {
        guard let executable = Bundle.main.executablePath else { return }
        writeCache(Cache(checkedAt: now, latest: latest))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [BuiltinFlags.updateCheckFlag]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try? process.run()
    }

    private struct Version {
        var core: [Int]
        var prerelease: [String]
    }

    private static func parse(_ text: String) -> Version? {
        let trimmed = text.hasPrefix("v") ? String(text.dropFirst()) : text
        guard trimmed.range(of: #"^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil else { return nil }
        let withoutBuild = trimmed.split(separator: "+", maxSplits: 1)[0]
        let parts = withoutBuild.split(separator: "-", maxSplits: 1)
        return Version(core: parts[0].split(separator: ".").map { Int($0) ?? 0 },
                       prerelease: parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : [])
    }

    /// Semver precedence comparison.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let a = parse(candidate), let b = parse(current) else { return false }
        for (x, y) in zip(a.core, b.core) where x != y { return x > y }
        if a.prerelease.isEmpty { return !b.prerelease.isEmpty }
        if b.prerelease.isEmpty { return false }
        for index in 0..<max(a.prerelease.count, b.prerelease.count) {
            guard index < a.prerelease.count else { return false }
            guard index < b.prerelease.count else { return true }
            let x = a.prerelease[index], y = b.prerelease[index]
            if x == y { continue }
            switch (Int(x), Int(y)) {
            case let (l?, r?): return l > r
            case (.some, nil): return false
            case (nil, .some): return true
            default: return x > y
            }
        }
        return false
    }
}
