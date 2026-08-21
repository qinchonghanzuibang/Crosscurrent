import Foundation
import NaturalLanguage

public struct CJKTokenSet: Codable, Hashable, Sendable {
    public var words: [String]
    public var hanUnigrams: [String]
    public var hanBigrams: [String]
    public var trigrams: [String]

    public init(words: [String], hanUnigrams: [String], hanBigrams: [String], trigrams: [String]) {
        self.words = words
        self.hanUnigrams = hanUnigrams
        self.hanBigrams = hanBigrams
        self.trigrams = trigrams
    }
}

public enum BilingualTokenizer {
    public static func tokenize(_ text: String, languageCode: String? = nil) -> CJKTokenSet {
        let normalized = text.precomposedStringWithCompatibilityMapping.lowercased()
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = normalized
        if let languageCode { tokenizer.setLanguage(NLLanguage(rawValue: languageCode)) }
        var words: [String] = []
        tokenizer.enumerateTokens(in: normalized.startIndex..<normalized.endIndex) { range, _ in
            let word = String(normalized[range]).trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
            if !word.isEmpty { words.append(word) }
            return true
        }

        let runs = hanRuns(in: normalized)
        let unigrams = runs.flatMap { $0.map(String.init) }
        let bigrams = runs.flatMap { characters -> [String] in
            guard characters.count >= 2 else { return [] }
            return (0..<(characters.count - 1)).map { String(characters[$0...($0 + 1)]) }
        }
        let scalars = Array(normalized)
        let trigrams = scalars.count >= 3 ? (0...(scalars.count - 3)).map { String(scalars[$0...($0 + 2)]) } : []
        return CJKTokenSet(words: stableUnique(words), hanUnigrams: stableUnique(unigrams), hanBigrams: stableUnique(bigrams), trigrams: stableUnique(trigrams))
    }

    public static func shortHanQueryToken(_ query: String) -> (token: String, length: Int)? {
        let characters = Array(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard (1...2).contains(characters.count), characters.allSatisfy({ $0.unicodeScalars.allSatisfy(isHan) }) else { return nil }
        return (String(characters), characters.count)
    }

    private static func hanRuns(in text: String) -> [[Character]] {
        var output: [[Character]] = []
        var current: [Character] = []
        for character in text {
            if character.unicodeScalars.allSatisfy(isHan) {
                current.append(character)
            } else if !current.isEmpty {
                output.append(current)
                current = []
            }
        }
        if !current.isEmpty { output.append(current) }
        return output
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: true
        default: false
        }
    }

    private static func stableUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
