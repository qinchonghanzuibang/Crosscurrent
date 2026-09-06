import Darwin
import Foundation

/// Shared URL boundary for automatic Reader media and hover-preview requests.
/// This validates literal hosts; redirects cross the same boundary independently.
public enum ReaderRemoteURLPolicy {
    public static func allows(_ url: URL, requiresHTTPS: Bool = false) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              requiresHTTPS ? scheme == "https" : ["http", "https"].contains(scheme),
              url.user == nil, url.password == nil,
              var host = url.host?.lowercased(), !host.isEmpty else { return false }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal") { return false }
        if host.contains(":") {
            var address = in6_addr()
            guard inet_pton(AF_INET6, host, &address) == 1 else { return false }
            let bytes = withUnsafeBytes(of: address) { Array($0) }
            // Unspecified, loopback, mapped IPv4, local, link-local, multicast,
            // and transition addresses are not automatic remote Reader assets.
            guard bytes[0] & 0xe0 == 0x20 else { return false }
            if bytes[0] == 0x20 && bytes[1] == 0x02 { return false } // 6to4
            return true
        }
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        let numeric = components.allSatisfy { $0.allSatisfy(\.isNumber) || $0.hasPrefix("0x") }
        if numeric {
            // Reject abbreviated, integer, hexadecimal and octal IPv4 spellings.
            guard components.count == 4 else { return false }
            let bytes = components.compactMap { UInt8($0) }
            guard bytes.count == 4, zip(components, bytes).allSatisfy({ String($0.0) == String($0.1) }) else { return false }
            return publicIPv4(bytes)
        }
        return !host.isEmpty && !host.contains("%")
    }

    private static func publicIPv4(_ bytes: [UInt8]) -> Bool {
        if [0, 10, 127].contains(bytes[0]) || bytes[0] >= 224 { return false }
        if bytes[0] == 169 && bytes[1] == 254 { return false }
        if bytes[0] == 172 && (16...31).contains(bytes[1]) { return false }
        if bytes[0] == 192 && (bytes[1] == 168 || bytes[1] == 0) { return false }
        if bytes[0] == 100 && (64...127).contains(bytes[1]) { return false }
        if bytes[0] == 198 && (18...19).contains(bytes[1]) { return false }
        return true
    }
}
