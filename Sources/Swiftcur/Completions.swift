import Foundation

/// Dynamic shell completions. The shell hook calls the binary with `COMPLETE=<shell>` on every tab press.
enum Completions {
    struct Candidate {
        var value: String
        var description: String?
        var noSpace = false
    }

    static func handle(runtime: Runtime, shell: String, argv: [String]) -> Int32 {
        let cli = runtime.cli
        let words = argv.firstIndex(of: "--").map { Array(argv[argv.index(after: $0)...]) } ?? argv
        guard !words.isEmpty else {
            runtime.io.stdout(([cli.name] + cli.aliases).map { register(shell, $0) }.joined(separator: "\n"))
            return 0
        }
        let index = runtime.io.environment["_COMPLETE_INDEX"].map { Int(jsNumber($0)) } ?? words.count - 1
        var candidates = complete(cli, words, index)
        let current = index < words.count ? words[index] : ""
        let nonFlags = words.prefix(index).filter { !$0.hasPrefix("-") }
        if nonFlags.count <= 1 {
            for builtin in runtime.builtins where builtin.name.hasPrefix(current) && !candidates.contains(where: { $0.value == builtin.name }) {
                candidates.append(Candidate(value: builtin.name, description: builtin.description, noSpace: !builtin.subcommands.isEmpty))
            }
        } else if nonFlags.count == 2, let builtin = Builtin.find(nonFlags.last),
                  runtime.builtins.contains(where: { $0.name == builtin.name }) {
            for sub in builtin.subcommands {
                for value in [sub.name] + sub.aliases where value.hasPrefix(current) && !candidates.contains(where: { $0.value == value }) {
                    candidates.append(Candidate(value: value, description: sub.description))
                }
            }
        }
        let output = format(shell, candidates)
        if !output.isEmpty { runtime.io.stdout(output) }
        return 0
    }

    static func complete(_ cli: CLI, _ argv: [String], _ index: Int) -> [Candidate] {
        let current = index < argv.count ? argv[index] : ""
        var scope = cli.commands
        var leaf = cli.root
        for token in argv.prefix(index) where !token.hasPrefix("-") {
            guard let entry = scope.resolved(token) else { continue }
            if case .group(let group) = entry {
                scope = group.commands
                leaf = group.root
            } else if case .command(let command) = entry {
                scope = Commands()
                leaf = command
                break
            }
        }

        var candidates: [Candidate] = []
        let globals = cli.globals
        if current.hasPrefix("-") {
            if let leaf, let options = leaf.options {
                for field in options.fields where "--\(toKebab(field.name))".hasPrefix(current) {
                    candidates.append(Candidate(value: "--\(toKebab(field.name))", description: field.schema.description))
                }
                for (name, short) in leaf.alias.sorted(by: { $0.key < $1.key }) where "-\(short)".hasPrefix(current) {
                    candidates.append(Candidate(value: "-\(short)", description: options[name]?.description))
                }
            }
            if let globals {
                for field in globals.fields {
                    let flag = "--\(toKebab(field.name))"
                    if flag.hasPrefix(current), !candidates.contains(where: { $0.value == flag }) {
                        candidates.append(Candidate(value: flag, description: field.schema.description))
                    }
                }
                for (name, short) in cli.globalAlias.sorted(by: { $0.key < $1.key }) {
                    let flag = "-\(short)"
                    if flag.hasPrefix(current), !candidates.contains(where: { $0.value == flag }) {
                        candidates.append(Candidate(value: flag, description: globals[name]?.description))
                    }
                }
            }
            return candidates
        }

        if index > 0, argv[index - 1].hasPrefix("-") {
            let previous = argv[index - 1]
            for (shape, alias) in [(leaf?.options, leaf?.alias ?? [:]), (globals, cli.globalAlias)] {
                guard let shape, let name = optionName(previous, shape, alias), let field = shape[name] else { continue }
                if let values = field.possibleValues {
                    return values.filter { $0.hasPrefix(current) }.map { Candidate(value: $0) }
                }
                if !(field.isBoolean || field.isCount) { return candidates }
            }
        }

        for (name, entry) in scope.canonical where name.hasPrefix(current) {
            switch entry {
            case .command(let command): candidates.append(Candidate(value: name, description: command.description))
            case .group(let group): candidates.append(Candidate(value: name, description: group.description, noSpace: true))
            case .alias: break
            }
        }
        return candidates
    }

    private static func optionName(_ token: String, _ shape: Shape, _ alias: [String: String]) -> String? {
        if token.hasPrefix("--") {
            let raw = String(token.dropFirst(2))
            return shape.names.first { $0 == raw || toKebab($0) == raw }
        }
        if token.count == 2 {
            let short = String(token.dropFirst())
            return alias.first { $0.value == short }?.key
        }
        return nil
    }

    static func format(_ shell: String, _ candidates: [Candidate]) -> String {
        switch shell {
        case "bash":
            return candidates.map { $0.noSpace ? "\($0.value)\u{01}" : $0.value }.joined(separator: "\u{0B}")
        case "zsh":
            return candidates.map { candidate in
                let escaped = candidate.value.replacingOccurrences(of: ":", with: "\\:")
                return candidate.description.map { "\(escaped):\($0)" } ?? escaped
            }.joined(separator: "\n")
        case "fish":
            return candidates.map { candidate in candidate.description.map { "\(candidate.value)\t\($0)" } ?? candidate.value }
                .joined(separator: "\n")
        case "nushell":
            return JSONWriter.stringify(.array(candidates.map { candidate in
                var record: JSONObject = ["value": .string(candidate.value)]
                if let description = candidate.description { record["description"] = .string(description) }
                return .object(record)
            }))
        default:
            return ""
        }
    }

    private static func identifier(_ name: String) -> String {
        name.replacingOccurrences(of: "[^a-zA-Z0-9_]", with: "_", options: .regularExpression)
    }

    /// The hook script a shell sources to enable completions.
    static func register(_ shell: String, _ name: String) -> String {
        let id = identifier(name)
        switch shell {
        case "bash":
            return """
            _swiftcur_complete_\(id)() {
                local IFS=$'\\013'
                local _COMPLETE_INDEX=${COMP_CWORD}
                local _completions
                _completions=( $(
                    export COMPLETE="bash"
                    export _COMPLETE_INDEX="$_COMPLETE_INDEX"
                    "\(name)" -- "${COMP_WORDS[@]}"
                ) )
                if [[ $? != 0 ]]; then
                    unset COMPREPLY
                    return
                fi
                local _nospace=false
                COMPREPLY=()
                for _c in "${_completions[@]}"; do
                    if [[ "$_c" == *$'\\001' ]]; then
                        _nospace=true
                        COMPREPLY+=("${_c%$'\\001'}")
                    else
                        COMPREPLY+=("$_c")
                    fi
                done
                if [[ $_nospace == true ]]; then
                    compopt -o nospace
                fi
            }
            complete -o default -o bashdefault -o nosort -F _swiftcur_complete_\(id) \(name)
            """
        case "zsh":
            return """
            #compdef \(name)
            _swiftcur_complete_\(id)() {
                local completions=("${(@f)$(
                    export _COMPLETE_INDEX=$(( CURRENT - 1 ))
                    export COMPLETE="zsh"
                    "\(name)" -- "${words[@]}" 2>/dev/null
                )}")
                if [[ -n $completions ]]; then
                    _describe 'values' completions -S ''
                fi
            }
            compdef _swiftcur_complete_\(id) \(name)
            """
        case "fish":
            return """
            complete --keep-order --exclusive --command \(name) \\
                --arguments "(COMPLETE=fish \(name) -- (commandline --current-process --tokenize --cut-at-cursor) (commandline --current-token))"
            """
        case "nushell":
            return """
            # External completer for \(name)
            # Add to $env.config.completions.external.completer or use in a dispatch completer.
            let _swiftcur_complete_\(id) = {|spans|
                COMPLETE=nushell \(name) -- ...$spans | from json
            }
            """
        default:
            return ""
        }
    }
}
