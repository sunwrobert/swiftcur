import Foundation

/// Throw from a command to fail with a specific error code.
public struct CommandError: Error, Sendable {
    public var code: String
    public var message: String
    public var hint: String?
    public var retryable: Bool
    public var exitCode: Int32?

    public init(code: String, message: String, hint: String? = nil, retryable: Bool = false, exitCode: Int32? = nil) {
        self.code = code
        self.message = message
        self.hint = hint
        self.retryable = retryable
        self.exitCode = exitCode
    }
}

/// Malformed argv or config: unknown flags, missing values.
public struct ParseError: Error, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// A field that failed validation.
public struct FieldError: Sendable, Equatable {
    public var code: String
    public var missing: Bool
    public var path: String
    public var expected: String
    public var received: String
    public var message: String

    var json: JSON {
        ["code": .string(code), "missing": .bool(missing), "path": .string(path),
         "expected": .string(expected), "received": .string(received), "message": .string(message)]
    }
}

/// Input that does not match the command's schema.
public struct ValidationError: Error, Sendable {
    public var message: String
    public var fieldErrors: [FieldError]

    init(issues: [Issue], raw: JSON) {
        let short = issues.map(\.message).joined(separator: "; ")
        let details = JSONWriter.stringify(.array(issues.map(\.json)), indent: 2)
        message = (short.isEmpty ? "Validation failed" : short) + "\n\nDetails: " + details
        fieldErrors = issues.map { issue in
            FieldError(code: issue.code, missing: !Self.hasPath(raw, issue.path), path: issue.pathText,
                       expected: issue.expected, received: issue.received, message: issue.message)
        }
    }

    private static func hasPath(_ data: JSON, _ path: [JSON]) -> Bool {
        var current = data
        for part in path {
            switch (current, part) {
            case (.object(let object), .string(let key)):
                guard let next = object[key] else { return false }
                current = next
            case (.array(let items), .number(let index)):
                guard items.indices.contains(Int(index)) else { return false }
                current = items[Int(index)]
            default:
                return false
            }
        }
        return true
    }
}

/// The error part of a failed command result.
struct ErrorInfo {
    var code: String
    var message: String
    var retryable: Bool?
    var fieldErrors: [FieldError]?

    var json: JSON {
        var object: JSONObject = ["code": .string(code), "message": .string(message)]
        if let retryable { object["retryable"] = .bool(retryable) }
        if let fieldErrors { object["fieldErrors"] = .array(fieldErrors.map(\.json)) }
        return .object(object)
    }

    static func from(_ error: Error) -> (ErrorInfo, exitCode: Int32?) {
        switch error {
        case let error as CommandError:
            return (ErrorInfo(code: error.code, message: error.message, retryable: error.retryable), error.exitCode)
        case let error as ValidationError:
            return (ErrorInfo(code: "VALIDATION_ERROR", message: error.message, fieldErrors: error.fieldErrors), nil)
        case let error as ParseError:
            return (ErrorInfo(code: "UNKNOWN", message: error.message), nil)
        default:
            return (ErrorInfo(code: "UNKNOWN", message: errorMessage(error)), nil)
        }
    }
}

func errorMessage(_ error: Error) -> String {
    switch error {
    case let error as CommandError: return error.message
    case let error as ParseError: return error.message
    case let error as ValidationError: return error.message
    case let error as LocalizedError: return error.errorDescription ?? "\(error)"
    default: return "\(error)"
    }
}
