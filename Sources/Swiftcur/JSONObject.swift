/// A string-keyed map that keeps insertion order.
public struct JSONObject: Equatable, Sendable, Sequence, ExpressibleByDictionaryLiteral {
    public private(set) var keys: [String] = []
    private var storage: [String: JSON] = [:]

    public init() {}

    public init(_ pairs: [(String, JSON)]) {
        for (key, value) in pairs { self[key] = value }
    }

    public init(dictionaryLiteral elements: (String, JSON)...) {
        self.init(elements)
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }
    public var values: [JSON] { keys.map { storage[$0]! } }

    public subscript(key: String) -> JSON? {
        get { storage[key] }
        set {
            guard let newValue else {
                removeValue(forKey: key)
                return
            }
            if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
        }
    }

    public func contains(_ key: String) -> Bool {
        storage[key] != nil
    }

    public mutating func removeValue(forKey key: String) {
        guard storage.removeValue(forKey: key) != nil else { return }
        keys.removeAll { $0 == key }
    }

    /// Copy with `other`'s keys applied on top, like `{ ...self, ...other }`.
    public func merging(_ other: JSONObject) -> JSONObject {
        var result = self
        for (key, value) in other { result[key] = value }
        return result
    }

    public func makeIterator() -> AnyIterator<(key: String, value: JSON)> {
        var index = 0
        return AnyIterator {
            guard index < keys.count else { return nil }
            defer { index += 1 }
            let key = keys[index]
            return (key, storage[key]!)
        }
    }

    public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
        lhs.keys == rhs.keys && lhs.storage == rhs.storage
    }
}
