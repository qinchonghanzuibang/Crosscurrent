import CryptoKit
import Foundation
import FeedFlowDomain

public enum ItemSegmenter {
    public static func segments(for revision: ItemRevision, aligningWith previous: [ItemSegment] = []) -> [ItemSegment] {
        let paragraphs = paragraphRanges(in: revision.text)
        let generated: [ItemSegment]
        if paragraphs.count <= 1 {
            generated = [segment(text: revision.text, byteOffset: 0, revisionID: revision.id, kind: .whole, headingPath: [])]
        } else {
            var headingPath: [String] = []
            generated = paragraphs.map { paragraph, offset in
                let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                let looksLikeHeading = trimmed.count < 100 && (trimmed.hasPrefix("#") || !trimmed.contains("。") && !trimmed.contains(".") && !trimmed.contains("，"))
                if looksLikeHeading { headingPath = [trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "# "))] }
                return segment(text: trimmed, byteOffset: offset, revisionID: revision.id, kind: looksLikeHeading ? .section : .paragraph, headingPath: headingPath)
            }
        }
        return align(generated, with: previous)
    }

    private static func paragraphRanges(in text: String) -> [(String, Int)] {
        var output: [(String, Int)] = []
        var byteOffset = 0
        for part in text.components(separatedBy: "\n\n") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let leading = part.utf8.count - part.drop(while: { $0.isWhitespace }).utf8.count
                output.append((trimmed, byteOffset + leading))
            }
            byteOffset += part.utf8.count + 2
        }
        return output
    }

    private static func segment(text: String, byteOffset: Int, revisionID: ItemRevisionID, kind: SegmentKind, headingPath: [String]) -> ItemSegment {
        let hash = digest(Data(text.utf8))
        return ItemSegment(
            lineageID: SegmentLineageID(stableUUID(hash: hash, salt: headingPath.joined(separator: "/"))),
            itemRevisionID: revisionID,
            kind: kind,
            headingPath: headingPath,
            span: TextSpan(utf8Start: byteOffset, utf8Length: text.utf8.count, excerptHash: hash),
            text: text,
            contentHash: hash
        )
    }

    private static func align(_ current: [ItemSegment], with previous: [ItemSegment]) -> [ItemSegment] {
        guard !previous.isEmpty else { return current }
        var output = current
        var available = Set(previous.indices)

        // Exact surviving spans keep their lineage regardless of movement.
        for index in output.indices {
            if let match = available.first(where: { previous[$0].contentHash == output[index].contentHash }) {
                output[index].lineageID = previous[match].lineageID
                available.remove(match)
            }
        }

        // Material edits are mapped conservatively. This lets durable user
        // constraints follow a paragraph across ordinary edits without binding
        // a completely replaced passage to its predecessor.
        for index in output.indices where !previous.contains(where: { $0.lineageID == output[index].lineageID }) {
            let ranked = available.map { priorIndex in
                (priorIndex, similarity(output[index], previous[priorIndex]))
            }.sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return previous[lhs.0].lineageID.description < previous[rhs.0].lineageID.description
            }
            let threshold = output.count == 1 && previous.count == 1 ? 0.50 : 0.67
            if let best = ranked.first, best.1 >= threshold {
                output[index].lineageID = previous[best.0].lineageID
                available.remove(best.0)
            }
        }
        return output
    }

    private static func similarity(_ lhs: ItemSegment, _ rhs: ItemSegment) -> Double {
        guard lhs.kind == rhs.kind || lhs.kind == .whole || rhs.kind == .whole else { return 0 }
        let left = characterBigrams(lhs.text)
        let right = characterBigrams(rhs.text)
        let union = left.union(right)
        let lexical = union.isEmpty ? (lhs.text == rhs.text ? 1 : 0) : Double(left.intersection(right).count) / Double(union.count)
        let larger = max(lhs.text.utf8.count, rhs.text.utf8.count)
        let length = larger == 0 ? 1 : Double(min(lhs.text.utf8.count, rhs.text.utf8.count)) / Double(larger)
        let heading = lhs.headingPath == rhs.headingPath ? 1.0 : 0.0
        return lexical * 0.72 + length * 0.18 + heading * 0.10
    }

    private static func characterBigrams(_ value: String) -> Set<String> {
        let characters = Array(value.precomposedStringWithCanonicalMapping.lowercased().filter { !$0.isWhitespace })
        guard characters.count > 1 else { return Set(characters.map(String.init)) }
        return Set(zip(characters, characters.dropFirst()).map { String($0) + String($1) })
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func stableUUID(hash: String, salt: String) -> UUID {
        let bytes = SHA256.hash(data: Data((hash + "|" + salt).utf8))
        var value = Array(bytes.prefix(16))
        value[6] = (value[6] & 0x0f) | 0x50
        value[8] = (value[8] & 0x3f) | 0x80
        return UUID(uuid: (value[0], value[1], value[2], value[3], value[4], value[5], value[6], value[7], value[8], value[9], value[10], value[11], value[12], value[13], value[14], value[15]))
    }
}
