import Foundation

/// Heuristic token counting, a port of the `tokenx` package incur uses (~96% accurate).
enum Tokens {
    private static let punctuation = CharacterSet(charactersIn: ".,!?;(){}[]<>:/\\|@#$%^&*+=`~_\"-")

    private static let languages: [(CharacterSet, Double)] = [
        (CharacterSet(charactersIn: "äöüßẞÄÖÜ"), 2.6),
        (CharacterSet(charactersIn: "éèêëàâîïôûùüÿçœæáíóúñÉÈÊËÀÂÎÏÔÛÙÜŸÇŒÆÁÍÓÚÑ"), 3),
        (CharacterSet(charactersIn: "ąćęłńóśźżěščřžýůúďťňĄĆĘŁŃÓŚŹŻĚŠČŘŽÝŮÚĎŤŇ"), 2.5),
        (CharacterSet(charactersIn: Unicode.Scalar(0x0430)!...Unicode.Scalar(0x044F)!)
            .union(CharacterSet(charactersIn: "ёЁ"))
            .union(CharacterSet(charactersIn: Unicode.Scalar(0x0410)!...Unicode.Scalar(0x042F)!)), 4),
        (CharacterSet(charactersIn: Unicode.Scalar(0x03AC)!...Unicode.Scalar(0x03CE)!), 2.75),
    ]

    private static let cjkRanges: [ClosedRange<UInt32>] = [
        0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3000...0x30FF, 0xFF00...0xFFEF, 0x2E80...0x2EFF, 0x31C0...0x31EF,
        0x3200...0x32FF, 0x3300...0x33FF, 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F,
        0xD7B0...0xD7FF,
    ]

    static func count(_ text: String) -> Int {
        segments(text).reduce(0) { $0 + $1.1 }
    }

    /// Text between token positions, like `tokenx.sliceByTokens`.
    static func slice(_ text: String, from start: Int, to end: Int) -> String {
        guard start < end else { return "" }
        var parts = ""
        var position = 0
        for (segment, tokens) in segments(text) {
            if position >= end { break }
            parts += part(segment, position, tokens, start, end)
            position += tokens
        }
        return parts
    }

    private static func part(_ segment: String, _ segmentStart: Int, _ count: Int, _ start: Int, _ end: Int) -> String {
        if count == 0 { return segmentStart >= start && segmentStart < end ? segment : "" }
        let segmentEnd = segmentStart + count
        if segmentStart >= end || segmentEnd <= start { return "" }
        let overlapStart = max(0, start - segmentStart)
        let overlapEnd = min(count, end - segmentStart)
        if overlapStart == 0, overlapEnd == count { return segment }
        let units = Array(segment.utf16)
        let from = Int((Double(overlapStart) / Double(count) * Double(units.count)).rounded(.down))
        let to = Int((Double(overlapEnd) / Double(count) * Double(units.count)).rounded(.up))
        return String(decoding: units[from..<min(to, units.count)], as: UTF16.self)
    }

    /// Splits on whitespace runs and punctuation runs, keeping the separators.
    private static func segments(_ text: String) -> [(String, Int)] {
        var result: [(String, Int)] = []
        var current = ""
        var currentKind = 0 // 0 word, 1 whitespace, 2 punctuation
        for scalar in text.unicodeScalars {
            let kind = CharacterSet.whitespacesAndNewlines.contains(scalar) ? 1 : punctuation.contains(scalar) ? 2 : 0
            if kind != currentKind, !current.isEmpty {
                result.append((current, estimate(current)))
                current = ""
            }
            currentKind = kind
            current.unicodeScalars.append(scalar)
        }
        if !current.isEmpty { result.append((current, estimate(current))) }
        return result
    }

    private static func estimate(_ segment: String) -> Int {
        let scalars = segment.unicodeScalars
        if scalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) {
            return segment.range(of: #"\n\s"#, options: .regularExpression) != nil ? 1 : 0
        }
        for (set, perToken) in languages where scalars.contains(where: { set.contains($0) }) {
            return Int((Double(segment.count) / perToken).rounded(.up))
        }
        if let first = scalars.first, first.properties.isEmojiPresentation || (first.properties.isEmoji && first.value > 0xFF),
           scalars.allSatisfy({ ($0.properties.isEmoji && $0.value > 0xFF) || $0.properties.isEmojiModifier || $0.value == 0x200D || $0.value == 0xFE0F }) {
            return Int((Double(segment.count) / 0.75).rounded(.up))
        }
        if scalars.contains(where: { s in cjkRanges.contains { $0.contains(s.value) } }) {
            var kana = 0, other = 0
            for scalar in scalars {
                if (0x3040...0x30FF).contains(scalar.value) { kana += 1 } else { other += 1 }
            }
            return other + Int((Double(kana) / 1.35).rounded(.up))
        }
        let length = segment.utf16.count
        if scalars.allSatisfy(\.isASCIIDigit) { return Int((Double(length) / 3).rounded(.up)) }
        if length <= 3 { return 1 }
        if scalars.contains(where: { punctuation.contains($0) }) { return Int((Double(length) / 2).rounded(.up)) }
        return Int((Double(length) / 6).rounded(.up))
    }
}
