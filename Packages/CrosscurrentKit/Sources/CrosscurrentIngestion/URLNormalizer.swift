import Foundation

public enum URLNormalizer {
    private static let trackingNames: Set<String> = [
        "fbclid", "gclid", "dclid", "mc_cid", "mc_eid", "igshid", "ref_src", "spm",
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "utm_id"
    ]

    public static func canonicalize(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        if (components.scheme == "https" && components.port == 443) || (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        components.queryItems = components.queryItems?
            .filter { !trackingNames.contains($0.name.lowercased()) && !$0.name.lowercased().hasPrefix("utm_") }
            .sorted { lhs, rhs in lhs.name == rhs.name ? (lhs.value ?? "") < (rhs.value ?? "") : lhs.name < rhs.name }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        if components.path.count > 1, components.path.hasSuffix("/") { components.path.removeLast() }
        return components.url ?? url
    }
}
