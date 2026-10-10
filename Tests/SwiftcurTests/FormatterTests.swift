import XCTest
@testable import Swiftcur

final class FormatterTests: XCTestCase {
    /// Expected strings come from @toon-format/toon 2.3.1, the encoder incur uses.
    func testToonMatchesReference() throws {
        let cases: [(String, String)] = [
            (#"{"a":1,"b":"x","c":true,"d":null}"#, "a: 1\nb: x\nc: true\nd: null"),
            (#"{"users":[{"id":1,"name":"Alice"},{"id":2,"name":"Bob"}]}"#, "users[2]{id,name}:\n  1,Alice\n  2,Bob"),
            (#"{"tags":["a","b c",""],"empty":[],"obj":{}}"#, "tags[3]: a,b c,\"\"\nempty: []\nobj:"),
            (#"{"nested":{"deep":{"k":"v"}}}"#, "nested:\n  deep:\n    k: v"),
            ("[1,2,3]", "[3]: 1,2,3"),
            (#"[{"a":1},{"b":2}]"#, "[2]:\n  - a: 1\n  - b: 2"),
            (#"{"mixed":[1,{"a":1},[1,2],"x"]}"#, "mixed[4]:\n  - 1\n  - a: 1\n  - [2]: 1,2\n  - x"),
            (##"{"s":["true","42","-x","a:b"," pad","has,comma","#h","é ok","05","1e5","null"]}"##,
             ##"s[11]: "true","42","-x","a:b"," pad","has,comma",#h,é ok,"05","1e5","null""##),
            (#"{"n":[1.5,0.1,1e21,1e-7,0,100,3,123456789012]}"#, "n[8]: 1.5,0.1,1e+21,1e-7,0,100,3,123456789012"),
            (#"{"my-key":1,"a.b":2,"9x":3}"#, "\"my-key\": 1\na.b: 2\n\"9x\": 3"),
            (#"{"rows":[{"a":1,"b":{"c":2,"d":3}},{"a":4,"b":{"c":5,"d":6}}]}"#,
             "rows[2]:\n  - a: 1\n    b:\n      c: 2\n      d: 3\n  - a: 4\n    b:\n      c: 5\n      d: 6"),
            (#"{"list":[{"a":1,"xs":[1,2]},{"a":2,"xs":[]}]}"#, "list[2]:\n  - a: 1\n    xs[2]: 1,2\n  - a: 2\n    xs: []"),
            (#"{"aoa":[[1,2],[],["x"]]}"#, "aoa[3]:\n  - [2]: 1,2\n  - [0]:\n  - [1]: x"),
            (#"{"line":"a\nb","q":"say \"hi\"","bs":"a\\b"}"#, #"line: "a\nb"\#nq: "say \"hi\""\#nbs: "a\\b""#),
            (#"{"emptyItem":[{},{"a":1}]}"#, "emptyItem[2]:\n  -\n  - a: 1"),
            ("[]", "[]"),
            ("{}", ""),
            (#"{"nestedList":[{"obj":{"x":1},"y":2}]}"#, "nestedList[1]:\n  - obj:\n      x: 1\n    y: 2"),
            (#"{"listFirstArr":[{"arr":[{"a":1},{"a":2}],"z":1}]}"#, "listFirstArr[1]:\n  - arr[2]{a}:\n      1\n      2\n    z: 1"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(Toon.encode(try JSONParser.parse(input)), expected, input)
        }
    }

    /// Expected strings come from the `yaml` npm package 2.8, which incur uses.
    func testYamlMatchesReference() throws {
        let cases: [(String, String)] = [
            (#"{"a":1,"b":"x","c":true,"d":null,"e":[1,"two"],"f":{"g":{"h":"i"}},"emp":[],"eo":{}}"#,
             "a: 1\nb: x\nc: true\nd: null\ne:\n  - 1\n  - two\nf:\n  g:\n    h: i\nemp: []\neo: {}\n"),
            (#"[{"id":1,"name":"A"},{"id":2}]"#, "- id: 1\n  name: A\n- id: 2\n"),
            (#""plain""#, "plain\n"),
            (#""a: b""#, "\"a: b\"\n"),
            (#""multi\nline""#, "|-\nmulti\nline\n"),
            (#"["- x","42","true",""," sp"]"#, "- \"- x\"\n- \"42\"\n- \"true\"\n- \"\"\n- \" sp\"\n"),
            (##"{"k":"yes","l":"No","m":"0x1","n":"1.0","o":"#c","p":"a #b","q":"it's","r":"say \"hi\""}"##,
             "k: yes\nl: No\nm: \"0x1\"\nn: \"1.0\"\no: \"#c\"\np: \"a #b\"\nq: it's\nr: say \"hi\"\n"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(Yaml.stringify(try JSONParser.parse(input)), expected, input)
        }
    }

    func testMarkdownTable() throws {
        let value = try JSONParser.parse(#"{"users":[{"id":1,"name":"Alice"},{"id":2,"name":"Bob"},{"id":3,"name":"Carol"}]}"#)
        XCTAssertEqual(
            Formatter.format(value, .md),
            "## users\n\n| id | name  |\n|----|-------|\n| 1  | Alice |\n| 2  | Bob   |\n| 3  | Carol |"
        )
    }

    func testNumbersMatchJavaScript() {
        let cases: [(Double, String)] = [
            (1, "1"), (1.5, "1.5"), (0.1, "0.1"), (1e21, "1e+21"), (1e-7, "1e-7"), (0.000001, "0.000001"),
            (123.456, "123.456"), (-0.0, "0"), (100, "100"), (123456789012, "123456789012"), (-2.5, "-2.5"),
            (9007199254740994, "9007199254740994"), (1e20, "100000000000000000000"),
        ]
        for (value, expected) in cases { XCTAssertEqual(JSONWriter.number(value), expected, "\(value)") }
    }

    func testJsonKeepsKeyOrder() throws {
        struct Row: Encodable { let zeta: Int; let alpha: String }
        XCTAssertEqual(JSONWriter.stringify(try JSON(encoding: Row(zeta: 1, alpha: "a"))), #"{"zeta":1,"alpha":"a"}"#)
    }
}

final class EncoderTests: XCTestCase {
    struct Inner: Encodable { let z: Int; let a: [String] }
    struct Outer: Encodable {
        let name: String
        let inner: Inner
        let list: [Inner]
        let optional: String?
        let map: [String: Int]
        let date: Date
    }

    /// Manual nested containers two levels deep, which synthesized Codable never produces.
    struct Manual: Encodable {
        enum K: String, CodingKey { case b, a }
        enum N: String, CodingKey { case y, x }
        func encode(to encoder: Encoder) throws {
            var root = encoder.container(keyedBy: K.self)
            var nested = root.nestedContainer(keyedBy: N.self, forKey: .b)
            try nested.encode(1, forKey: .y)
            var deeper = nested.nestedUnkeyedContainer(forKey: .x)
            try deeper.encode("p")
            var item = deeper.nestedContainer(keyedBy: N.self)
            try item.encode(true, forKey: .y)
            try root.encode("last", forKey: .a)
        }
    }

    func testKeepsOrderThroughNesting() throws {
        let value = Outer(name: "n", inner: Inner(z: 1, a: ["x"]), list: [Inner(z: 2, a: [])], optional: nil,
                          map: ["k": 1], date: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(JSONWriter.stringify(try JSON(encoding: value)),
                       #"{"name":"n","inner":{"z":1,"a":["x"]},"list":[{"z":2,"a":[]}],"map":{"k":1},"date":"1970-01-01T00:00:00Z"}"#)
    }

    func testDeepManualContainers() throws {
        XCTAssertEqual(JSONWriter.stringify(try JSON(encoding: Manual())), #"{"b":{"y":1,"x":["p",{"y":true}]},"a":"last"}"#)
    }

    func testDecodesBack() throws {
        struct Point: Codable, Equatable { let x: Int; let y: Double }
        let json: JSON = ["x": 1, "y": 2.5]
        XCTAssertEqual(try json.decode(Point.self), Point(x: 1, y: 2.5))
    }
}
