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

        let blocks = (try? body.select("h1, h2, h3, p, li, figcaption, blockquote"))?.array() ?? []
        let values = blocks.compactMap { element -> String? in
            guard let text = try? element.text().trimmingCharacters(in: .whitespacesAndNewlines),
                  text.count >= 24
            else { return nil }
            return text
        }
        return values.joined(separator: "\n\n")
    }
}
