import XCTest
@testable import Swiftcur

/// Expected JSON Schemas and issues come from Zod 4 via incur's `Schema.toJsonSchema`.
final class SchemaTests: XCTestCase {
    private func schema(_ shape: Shape) -> String {
        JSONWriter.stringify(.object(Schema.objectSchema(shape)))
    }

    func testJsonSchemaMatchesZod() {
        XCTAssertEqual(schema(["a": .string.optional()]),
                       #"{"type":"object","properties":{"a":{"type":"string"}},"additionalProperties":false}"#)
        XCTAssertEqual(schema([:]), #"{"type":"object","properties":{},"additionalProperties":false}"#)
        XCTAssertEqual(schema(["a": .string.default("x").describe("d")]),
                       #"{"type":"object","properties":{"a":{"default":"x","description":"d","type":"string"}},"required":["a"],"additionalProperties":false}"#)
        XCTAssertEqual(schema(["a": .string.describe("d").default("x")]),
                       #"{"type":"object","properties":{"a":{"default":"x","type":"string","description":"d"}},"required":["a"],"additionalProperties":false}"#)
        XCTAssertEqual(schema(["a": .boolean.optional().describe("d")]),
                       #"{"type":"object","properties":{"a":{"description":"d","type":"boolean"}},"additionalProperties":false}"#)
        XCTAssertEqual(schema(["a": .choice("x", "y").default("x").describe("d")]),
                       #"{"type":"object","properties":{"a":{"default":"x","description":"d","type":"string","enum":["x","y"]}},"required":["a"],"additionalProperties":false}"#)
        XCTAssertEqual(schema(["a": .int.min(1).max(20).default(5).describe("d")]),
                       #"{"type":"object","properties":{"a":{"default":5,"description":"d","type":"integer","minimum":1,"maximum":20}},"required":["a"],"additionalProperties":false}"#)
        XCTAssertEqual(schema(["a": .string.max(3), "b": .array(.number).min(1)]),
                       #"{"type":"object","properties":{"a":{"type":"string","maxLength":3},"b":{"minItems":1,"type":"array","items":{"type":"number"}}},"required":["a","b"],"additionalProperties":false}"#)
        XCTAssertEqual(schema(["c": .count, "dep": .string.optional().describe("old").deprecated(),
                               "lit": .literals("x", "y").optional()]),
                       #"{"type":"object","properties":{"c":{"default":0,"count":true,"type":"number"},"dep":{"description":"old","deprecated":true,"type":"string"},"lit":{"anyOf":[{"type":"string","const":"x"},{"type":"string","const":"y"}]}},"required":["c"],"additionalProperties":false}"#)
    }

    func testIssuesMatchZod() {
        let shape: Shape = ["a": .string.max(3), "b": .array(.number).min(1), "c": .number, "d": .boolean,
                            "e": .array(.string), "f": .int]
        XCTAssertThrowsError(try Schema.parse(shape, ["a": "abcd", "b": [], "c": "x", "d": 1, "e": "x", "f": "y"])) { error in
            let messages = (error as! ValidationError).fieldErrors.map(\.message)
            XCTAssertEqual(messages, [
                "Too big: expected string to have <=3 characters",
                "Too small: expected array to have >=1 items",
                "Invalid input: expected number, received string",
                "Invalid input: expected boolean, received number",
                "Invalid input: expected array, received string",
                "Invalid input: expected number, received string",
            ])
        }
        XCTAssertThrowsError(try Schema.parse(["name": .string, "e": .choice("a", "b")], [:])) { error in
            let validation = error as! ValidationError
            XCTAssertEqual(validation.fieldErrors.map(\.message), [
                "Invalid input: expected string, received undefined",
                #"Invalid option: expected one of "a"|"b""#,
            ])
            XCTAssertEqual(validation.fieldErrors.map(\.missing), [true, true])
        }
    }
}
