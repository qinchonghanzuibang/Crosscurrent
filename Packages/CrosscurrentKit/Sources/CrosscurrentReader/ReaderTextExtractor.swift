import Foundation
import SwiftSoup

public enum ReaderTextExtractor {
    public static func plainText(fromSanitizedHTML html: String) -> String {
        guard let document = try? SwiftSoup.parseBodyFragment(html),
              let body = document.body()
        else { return "" }

        for selector in ["script", "style", "nav", "footer", "aside", "form"] {
            _ = try? body.select(selector).remove()
        }

        let blockTags = Set(["h1", "h2", "h3", "h4", "h5", "h6", "p", "li", "dt", "dd", "figcaption", "blockquote", "pre", "tr"])
        let blocks = (try? body.select(blockTags.sorted().joined(separator: ",")))?.array() ?? []
        let values = blocks.compactMap { element -> String? in
            // A quote/list can contain paragraphs or nested lists. Extract its
            // text once, rather than sending duplicated passages to Insights.
            guard !element.parents().contains(where: { blockTags.contains($0.tagName()) }) else { return nil }
            guard let text = try? element.text().trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { return nil }
            return text
        }
        return values.isEmpty ? ((try? body.text()) ?? "") : values.joined(separator: "\n\n")
    }
}
