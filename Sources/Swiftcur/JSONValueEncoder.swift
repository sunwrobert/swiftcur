import Foundation

/// Encodes `Encodable` values straight to `JSON`, keeping keys in the order they are encoded.
/// (`JSONEncoder` goes through a dictionary and loses struct field order.)
struct JSONValueEncoder {
    func encode<T: Encodable>(_ value: T) throws -> JSON {
        if let json = value as? JSON { return json }
        let node = Node()
        try value.encode(to: Writer(node: node, codingPath: []))
        return node.json
    }

    /// A mutable value in the tree being built. Containers hold references, so nesting needs no write-back.
    fileprivate final class Node {
        enum Content {
            case empty
            case value(JSON)
            case object(keys: [String], children: [String: Node])
            case array([Node])
        }

        var content: Content = .empty

        init() {}
        init(_ json: JSON) { content = .value(json) }

        var json: JSON {
            switch content {
            case .empty: return .object(JSONObject())
            case .value(let json): return json
            case .array(let nodes): return .array(nodes.map(\.json))
            case .object(let keys, let children): return .object(JSONObject(keys.map { ($0, children[$0]!.json) }))
            }
        }

        func set(_ key: String, _ node: Node) {
            if case .object(var keys, var children) = content {
                if children[key] == nil { keys.append(key) }
                children[key] = node
                content = .object(keys: keys, children: children)
            } else {
                content = .object(keys: [key], children: [key: node])
            }
        }

        func append(_ node: Node) {
            if case .array(var nodes) = content {
                nodes.append(node)
                content = .array(nodes)
            } else {
                content = .array([node])
            }
        }

        var arrayCount: Int {
            if case .array(let nodes) = content { return nodes.count }
            return 0
        }

        func ensureObject() {
            if case .object = content { return }
            content = .object(keys: [], children: [:])
        }

        func ensureArray() {
            if case .array = content { return }
            content = .array([])
        }
    }

    /// Encodes a nested value, special-casing Foundation types the way `JSONEncoder` does by default.
    fileprivate static func node<T: Encodable>(_ value: T, path: [CodingKey]) throws -> Node {
        switch value {
        case let json as JSON: return Node(json)
        case let date as Date: return Node(.string(ISO8601DateFormatter().string(from: date)))
        case let url as URL: return Node(.string(url.absoluteString))
        case let data as Data: return Node(.string(data.base64EncodedString()))
        case let decimal as Decimal: return Node(.number(NSDecimalNumber(decimal: decimal).doubleValue))
        default:
            let node = Node()
            try value.encode(to: Writer(node: node, codingPath: path))
            return node
        }
    }

    fileprivate struct Writer: Encoder {
        let node: Node
        let codingPath: [CodingKey]
        var userInfo: [CodingUserInfoKey: Any] { [:] }

        func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
            node.ensureObject()
            return KeyedEncodingContainer(Keyed<Key>(node: node, codingPath: codingPath))
        }

        func unkeyedContainer() -> UnkeyedEncodingContainer {
            node.ensureArray()
            return Unkeyed(node: node, codingPath: codingPath)
        }

        func singleValueContainer() -> SingleValueEncodingContainer {
            Single(node: node, codingPath: codingPath)
        }
    }

    fileprivate struct Keyed<Key: CodingKey>: KeyedEncodingContainerProtocol {
        let node: Node
        let codingPath: [CodingKey]

        mutating func encodeNil(forKey key: Key) throws { node.set(key.stringValue, Node(.null)) }
        mutating func encode(_ value: Bool, forKey key: Key) throws { node.set(key.stringValue, Node(.bool(value))) }
        mutating func encode(_ value: String, forKey key: Key) throws { node.set(key.stringValue, Node(.string(value))) }
        mutating func encode(_ value: Double, forKey key: Key) throws { node.set(key.stringValue, Node(.number(value))) }
        mutating func encode(_ value: Int, forKey key: Key) throws { node.set(key.stringValue, Node(.number(Double(value)))) }

        mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
            node.set(key.stringValue, try JSONValueEncoder.node(value, path: codingPath + [key]))
        }

        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type, forKey key: Key)
            -> KeyedEncodingContainer<NestedKey> {
            let child = Node()
            child.ensureObject()
            node.set(key.stringValue, child)
            return KeyedEncodingContainer(Keyed<NestedKey>(node: child, codingPath: codingPath + [key]))
        }

        mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
            let child = Node()
            child.ensureArray()
            node.set(key.stringValue, child)
            return Unkeyed(node: child, codingPath: codingPath + [key])
        }

        mutating func superEncoder() -> Encoder { superEncoder(forKey: Key(stringValue: "super")!) }

        mutating func superEncoder(forKey key: Key) -> Encoder {
            let child = Node()
            node.set(key.stringValue, child)
            return Writer(node: child, codingPath: codingPath + [key])
        }
    }

    fileprivate struct Unkeyed: UnkeyedEncodingContainer {
        let node: Node
        let codingPath: [CodingKey]
        var count: Int { node.arrayCount }

        mutating func encodeNil() throws { node.append(Node(.null)) }
        mutating func encode(_ value: Bool) throws { node.append(Node(.bool(value))) }
        mutating func encode(_ value: String) throws { node.append(Node(.string(value))) }
        mutating func encode(_ value: Double) throws { node.append(Node(.number(value))) }
        mutating func encode(_ value: Int) throws { node.append(Node(.number(Double(value)))) }

        mutating func encode<T: Encodable>(_ value: T) throws {
            node.append(try JSONValueEncoder.node(value, path: codingPath))
        }

        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
            let child = Node()
            child.ensureObject()
            node.append(child)
            return KeyedEncodingContainer(Keyed<NestedKey>(node: child, codingPath: codingPath))
        }

        mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
            let child = Node()
            child.ensureArray()
            node.append(child)
            return Unkeyed(node: child, codingPath: codingPath)
        }

        mutating func superEncoder() -> Encoder {
            let child = Node()
            node.append(child)
            return Writer(node: child, codingPath: codingPath)
        }
    }

    fileprivate struct Single: SingleValueEncodingContainer {
        let node: Node
        let codingPath: [CodingKey]

        mutating func encodeNil() throws { node.content = .value(.null) }
        mutating func encode(_ value: Bool) throws { node.content = .value(.bool(value)) }
        mutating func encode(_ value: String) throws { node.content = .value(.string(value)) }
        mutating func encode(_ value: Double) throws { node.content = .value(.number(value)) }
        mutating func encode(_ value: Float) throws { node.content = .value(.number(Double(value))) }
        mutating func encode(_ value: Int) throws { node.content = .value(.number(Double(value))) }
        mutating func encode(_ value: Int8) throws { node.content = .value(.number(Double(value))) }
        mutating func encode(_ value: Int16) throws { node.content = .value(.number(Double(value))) }
        mutating func encode(_ value: Int32) throws { node.content = .value(.number(Double(value))) }
        mutating func encode(_ value: Int64) throws { node.content = .value(.number(Double(value))) }
        mutating func encode(_ value: UInt) throws { node.content = .value(.number(Double(value))) }
        mutating func encode(_ value: UInt8) throws { node.content = .value(.number(Double(value))) }
        mutating func encode(_ value: UInt16) throws { node.content = .value(.number(Double(value))) }
        mutating func encode(_ value: UInt32) throws { node.content = .value(.number(Double(value))) }
        mutating func encode(_ value: UInt64) throws { node.content = .value(.number(Double(value))) }

        mutating func encode<T: Encodable>(_ value: T) throws {
            node.content = try JSONValueEncoder.node(value, path: codingPath).content
        }
    }
}
