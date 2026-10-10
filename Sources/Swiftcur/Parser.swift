import Foundation

/// Parses argv tokens against arg and option shapes.
enum Parser {
    struct Names {
        var aliasToName: [String: String] = [:]
        var kebabToCamel: [String: String] = [:]
        var known: Set<String> = []

        init(_ shape: Shape?, _ alias: [String: String]) {
            for (name, short) in alias { aliasToName[short] = name }
            for name in shape?.names ?? [] {
                known.insert(name)
                let kebab = toKebab(name)
                if kebab != name { kebabToCamel[kebab] = name }
            }
        }

        func normalize(_ raw: String) -> String? {
            let name = kebabToCamel[raw] ?? raw
            return known.contains(name) ? name : nil
        }
    }

    /// Splits argv into args and options, then validates both.
    static func parse(_ argv: [String], args: Shape?, options: Shape?, alias: [String: String] = [:],
                      defaults: JSONObject? = nil) throws -> (args: JSONObject, options: JSONObject) {
        let names = Names(options, alias)
        var positionals: [String] = []
        var raw = JSONObject()
        var index = 0

        while index < argv.count {
            let token = argv[index]
            if token.hasPrefix("--no-"), token.count > 5 {
                guard let name = names.normalize(String(token.dropFirst(5))) else { throw ParseError("Unknown flag: \(token)") }
                raw[name] = false
                index += 1
            } else if token.hasPrefix("--") {
                let body = String(token.dropFirst(2))
                if let equals = body.firstIndex(of: "=") {
                    let flag = String(body[..<equals])
                    guard let name = names.normalize(flag) else { throw ParseError("Unknown flag: --\(flag)") }
                    set(&raw, name, String(body[body.index(after: equals)...]), options)
                    index += 1
                } else {
                    guard let name = names.normalize(body) else { throw ParseError("Unknown flag: \(token)") }
                    let field = options?[name]
                    if field?.isCount == true {
                        raw[name] = .number((raw[name]?.doubleValue ?? 0) + 1)
                        index += 1
                    } else if field?.isBoolean == true {
                        raw[name] = true
                        index += 1
                    } else {
                        guard index + 1 < argv.count else { throw ParseError("Missing value for flag: \(token)") }
                        set(&raw, name, argv[index + 1], options)
                        index += 2
                    }
                }
            } else if token.hasPrefix("-"), token.count >= 2 {
                index += try shortFlags(token, argv: argv, at: index, names: names, shape: options, raw: &raw, strict: true)
            } else {
                positionals.append(token)
                index += 1
            }
        }

        var rawArgs = JSONObject()
        if let args {
            for (offset, field) in args.fields.enumerated() {
                if field.schema.isArray {
                    guard offset == args.fields.count - 1 else {
                        throw ParseError("Variadic arg \"\(field.name)\" must be the last key in the args schema")
                    }
                    let rest = Array(positionals.dropFirst(offset))
                    if !rest.isEmpty { rawArgs[field.name] = .array(rest.map(JSON.string)) }
                } else if offset < positionals.count {
                    rawArgs[field.name] = .string(positionals[offset])
                }
            }
        }
        let parsedArgs = try args.map { try Schema.parse($0, rawArgs) } ?? JSONObject()

        var merged = try normalizeDefaults(defaults, options, names)
        if let options {
            for (name, value) in raw { merged[name] = coerce(value, options[name]) }
        }
        let parsedOptions = try options.map { try Schema.parse($0, merged) } ?? JSONObject()
        return (parsedArgs, parsedOptions)
    }

    /// Parses known global flags and passes everything else through.
    static func parseGlobals(_ argv: [String], schema: Shape, alias: [String: String], validate: Bool) throws
        -> (parsed: JSONObject, rest: [String]) {
        let names = Names(schema, alias)
        var rest: [String] = []
        var raw = JSONObject()
        var index = 0

        while index < argv.count {
            let token = argv[index]
            if token == "--" {
                rest.append(contentsOf: argv[index...])
                break
            }
            if token.hasPrefix("--no-"), token.count > 5 {
                if let name = names.normalize(String(token.dropFirst(5))) { raw[name] = false } else { rest.append(token) }
                index += 1
            } else if token.hasPrefix("--") {
                let body = String(token.dropFirst(2))
                if let equals = body.firstIndex(of: "=") {
                    if let name = names.normalize(String(body[..<equals])) {
                        set(&raw, name, String(body[body.index(after: equals)...]), schema)
                    } else {
                        rest.append(token)
                    }
                    index += 1
                } else if let name = names.normalize(body) {
                    let field = schema[name]
                    if field?.isCount == true {
                        raw[name] = .number((raw[name]?.doubleValue ?? 0) + 1)
                        index += 1
                    } else if field?.isBoolean == true {
                        raw[name] = true
                        index += 1
                    } else {
                        guard index + 1 < argv.count else { throw ParseError("Missing value for flag: \(token)") }
                        set(&raw, name, argv[index + 1], schema)
                        index += 2
                    }
                } else {
                    rest.append(token)
                    index += 1
                }
            } else if token.hasPrefix("-"), token.count >= 2 {
                if token.dropFirst().allSatisfy({ names.aliasToName[String($0)] != nil }) {
                    index += try shortFlags(token, argv: argv, at: index, names: names, shape: schema, raw: &raw, strict: true)
                } else {
                    rest.append(token)
                    index += 1
                }
            } else {
                rest.append(token)
                index += 1
            }
        }

        guard validate else { return (raw, rest) }
        var coercedRaw = JSONObject()
        for (name, value) in raw { coercedRaw[name] = coerce(value, schema[name]) }
        return (try Schema.parse(schema, coercedRaw), rest)
    }

    /// Reads environment variables declared in a shape.
    static func parseEnv(_ shape: Shape, _ source: [String: String]) throws -> JSONObject {
        var raw = JSONObject()
        for field in shape.fields {
            guard let value = source[field.name] else { continue }
            switch field.schema.kind {
            case .number, .integer: raw[field.name] = .number(jsNumber(value))
            case .boolean: raw[field.name] = .bool(value == "true" || value == "1")
            default: raw[field.name] = .string(value)
            }
        }
        return try Schema.parse(shape, raw)
    }

    // MARK: Helpers

    /// Handles `-a` and stacked `-abc`. Returns how many argv tokens were consumed.
    private static func shortFlags(_ token: String, argv: [String], at index: Int, names: Names, shape: Shape?,
                                   raw: inout JSONObject, strict: Bool) throws -> Int {
        let characters = Array(token.dropFirst())
        var consumed = 1
        for (offset, character) in characters.enumerated() {
            let short = String(character)
            guard let name = names.aliasToName[short] else { throw ParseError("Unknown flag: -\(short)") }
            let field = shape?[name]
            let isLast = offset == characters.count - 1
            if field?.isCount == true {
                raw[name] = .number((raw[name]?.doubleValue ?? 0) + 1)
            } else if field?.isBoolean == true {
                raw[name] = true
            } else if !isLast {
                throw ParseError("Non-boolean flag -\(short) must be last in a stacked alias")
            } else {
                guard index + 1 < argv.count else { throw ParseError("Missing value for flag: -\(short)") }
                set(&raw, name, argv[index + 1], shape)
                consumed = 2
            }
        }
        return consumed
    }

    private static func set(_ raw: inout JSONObject, _ name: String, _ value: String, _ shape: Shape?) {
        guard shape?[name]?.isArray == true else {
            raw[name] = .string(value)
            return
        }
        raw[name] = .array((raw[name]?.arrayValue ?? []) + [.string(value)])
    }

    private static func coerce(_ value: JSON, _ field: Schema?) -> JSON {
        guard let field, case .string(let text) = value else { return value }
        switch field.kind {
        case .number, .integer: return .number(jsNumber(text))
        case .boolean: return .bool(text == "true")
        default: return value
        }
    }

    private static func normalizeDefaults(_ defaults: JSONObject?, _ shape: Shape?, _ names: Names) throws -> JSONObject {
        guard let defaults else { return JSONObject() }
        guard shape != nil else {
            if let first = defaults.keys.first { throw ParseError("Unknown config option: \(first)") }
            return JSONObject()
        }
        var normalized = JSONObject()
        for (key, value) in defaults {
            guard let name = names.normalize(key) else { throw ParseError("Unknown config option: \(key)") }
            normalized[name] = value
        }
        return normalized
    }
}

/// `saveDev` → `save-dev`.
func toKebab(_ name: String) -> String {
    var out = ""
    for character in name {
        if character.isUppercase, character.isASCII {
            out += "-" + character.lowercased()
        } else {
            out.append(character)
        }
    }
    return out
}

/// Closest candidate for a mistyped command, or nil.
func suggest(_ input: String, _ candidates: [String]) -> String? {
    let threshold = input.count <= 4 ? 2 : input.count / 2
    let lower = input.lowercased()
    var best: String?
    var bestScore = Int.max
    for candidate in candidates {
        let lowered = candidate.lowercased()
        let distance = levenshtein(lower, lowered)
        let score: Int
        if lowered.hasPrefix(lower), lowered != lower {
            score = distance
        } else if lowered.contains(lower) {
            score = 100 + distance
        } else if distance <= threshold {
            score = 200 + distance
        } else {
            continue
        }
        if score < bestScore {
            bestScore = score
            best = candidate
        }
    }
    return best
}

func levenshtein(_ a: String, _ b: String) -> Int {
    let left = Array(a.utf16), right = Array(b.utf16)
    var row = Array(0...right.count)
    for i in 1...max(left.count, 1) where !left.isEmpty {
        var previous = row[0]
        row[0] = i
        for j in stride(from: 1, through: right.count, by: 1) {
            let saved = row[j]
            row[j] = left[i - 1] == right[j - 1] ? previous : 1 + Swift.min(previous, row[j], row[j - 1])
            previous = saved
        }
    }
    return row[right.count]
}
