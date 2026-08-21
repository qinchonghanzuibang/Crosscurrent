import CryptoKit
import CrosscurrentConnectors
import CrosscurrentDomain
import CrosscurrentStorage
import Foundation

/// Conservative enrichment that turns connector metadata and exact known aliases into
/// revision- and span-bound assertions. It deliberately does not guess ambiguous entities.
public actor ProviderFreeEnrichmentStage {
    private let repository: CrosscurrentRepository

    public init(repository: CrosscurrentRepository) {
        self.repository = repository
    }

    public func enrich(
        candidate: ConnectorItemCandidate,
        sourceID: SourceID,
        revision: ItemRevision,
        segments: [ItemSegment]
    ) async throws {
        if let host = candidate.canonicalURL?.host?.lowercased(), Self.isMeaningfulDomain(host) {
            _ = try await repository.resolveOrCreateEntity(
                displayName: host,
                kind: .organization,
                languageCode: revision.languageCode,
                sourceID: sourceID,
                sourceRole: .publishedBy,
                provenance: .deterministic,
                confidence: Confidence(0.88),
                at: revision.fetchedAt
            )
        }

        for author in Self.structuredAuthors(candidate.author) {
            _ = try await repository.resolveOrCreateEntity(
                displayName: author,
                kind: .person,
                languageCode: revision.languageCode,
                provenance: .connector,
                confidence: Confidence(0.92),
                at: revision.fetchedAt
            )
        }

        let aliases = try await repository.entityAliasesForEnrichment(sourceID: sourceID)
        var mentions: [ItemEntityMention] = []
        var seen: Set<String> = []
        for segment in segments {
            for alias in aliases where Self.qualifies(alias: alias) {
                for range in Self.exactRanges(of: alias.value, in: segment.text) {
                    let key = "\(segment.id):\(alias.entityID):\(range.lowerBound):\(range.count)"
                    guard seen.insert(key).inserted else { continue }
                    let mentioned = Self.utf8Substring(segment.text, range: range)
                    mentions.append(ItemEntityMention(
                        itemRevisionID: revision.id,
                        itemSegmentID: segment.id,
                        entityID: alias.entityID,
                        span: TextSpan(
                            utf8Start: segment.span.utf8Start + range.lowerBound,
                            utf8Length: range.count,
                            excerptHash: Self.sha256(mentioned)
                        ),
                        mentionedText: mentioned,
                        provenance: alias.confidence.value >= 0.9 ? .connector : .deterministic,
                        confidence: Confidence(min(0.96, alias.confidence.value))
                    ))
                }
            }
        }
        _ = try await repository.saveItemEntityMentions(
            mentions,
            idempotencyKey: "enrichment:entities:\(revision.id):\(revision.contentHash)"
        )
    }

    private static func structuredAuthors(_ value: String?) -> [String] {
        guard let value else { return [] }
        let candidates = value
            .split(whereSeparator: { ",;、，；\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 && $0.count <= 100 }
        return candidates.count <= 12 ? Array(Set(candidates)).sorted() : []
    }

    private static func isMeaningfulDomain(_ host: String) -> Bool {
        !host.isEmpty && host != "localhost" && !host.hasSuffix(".local")
    }

    private static func qualifies(alias: StoredEntityAlias) -> Bool {
        guard alias.confidence.value >= 0.8 else { return false }
        let length = alias.normalizedValue.unicodeScalars.count
        return length >= 2 && length <= 100
    }

    /// Returns offsets into the original UTF-8 buffer. Foundation performs the
    /// case/diacritic comparison but returns ranges in the original string, so a
    /// folded spelling such as "Cafe" can never shift or truncate the bytes for
    /// an original spelling such as "CAFÉ".
    private static func exactRanges(of needle: String, in haystack: String) -> [Range<Int>] {
        guard !needle.isEmpty else { return [] }
        let requiresBoundary = needle.unicodeScalars.contains {
            $0.value < 0x2E80 && CharacterSet.alphanumerics.contains($0)
        }
        var result: [Range<Int>] = []
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let match = haystack.range(
            of: needle,
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            range: searchRange,
            locale: Locale(identifier: "en_US_POSIX")
        ) {
            if !requiresBoundary || (isBoundary(haystack, before: match.lowerBound) && isBoundary(haystack, after: match.upperBound)) {
                let lower = haystack[..<match.lowerBound].utf8.count
                let length = haystack[match].utf8.count
                result.append(lower..<(lower + length))
            }
            guard match.upperBound < haystack.endIndex else { break }
            searchRange = match.upperBound..<haystack.endIndex
        }
        return result
    }

    private static func isBoundary(_ value: String, before index: String.Index) -> Bool {
        guard index > value.startIndex else { return true }
        return !isWordCharacter(value[value.index(before: index)])
    }

    private static func isBoundary(_ value: String, after index: String.Index) -> Bool {
        guard index < value.endIndex else { return true }
        return !isWordCharacter(value[index])
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character == "_" || character.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0)
        }
    }

    private static func utf8Substring(_ value: String, range: Range<Int>) -> String {
        let bytes = Array(value.utf8)
        guard range.lowerBound >= 0, range.upperBound <= bytes.count else { return "" }
        return String(decoding: bytes[range], as: UTF8.self)
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
