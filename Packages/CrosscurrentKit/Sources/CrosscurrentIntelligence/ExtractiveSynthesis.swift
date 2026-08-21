import Foundation
import NaturalLanguage

public struct ExtractiveSentence: Codable, Hashable, Sendable {
    public var text: String
    public var utf8Start: Int
    public var utf8Length: Int
    public var score: Double

    public init(text: String, utf8Start: Int, utf8Length: Int, score: Double) {
        self.text = text
        self.utf8Start = utf8Start
        self.utf8Length = utf8Length
        self.score = score
    }
}

public enum ExtractiveSynthesis {
    public static func keySentences(from text: String, limit: Int = 3) -> [ExtractiveSentence] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var candidates: [ExtractiveSentence] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard sentence.count >= 20 else { return true }
            let prefix = text[..<range.lowerBound]
            let byteStart = prefix.utf8.count
            let signal = min(1, Double(sentence.count) / 180)
            let numeralBoost = sentence.rangeOfCharacter(from: .decimalDigits) == nil ? 0 : 0.12
            let attributionBoost = sentence.contains("表示") || sentence.contains("said") || sentence.contains("according") ? 0.08 : 0
            candidates.append(.init(text: sentence, utf8Start: byteStart, utf8Length: sentence.utf8.count, score: signal + numeralBoost + attributionBoost))
            return true
        }
        return candidates.enumerated()
            .sorted { lhs, rhs in lhs.element.score == rhs.element.score ? lhs.offset < rhs.offset : lhs.element.score > rhs.element.score }
            .prefix(max(1, limit))
            .map(\.element)
            .sorted { $0.utf8Start < $1.utf8Start }
    }

    public static func summary(from text: String, limit: Int = 3) -> String {
        keySentences(from: text, limit: limit).map(\.text).joined(separator: " ")
    }
}
