import CrosscurrentDomain
import Foundation
import UniformTypeIdentifiers

final class ShareExtensionHandler: NSObject, NSExtensionRequestHandling, @unchecked Sendable {
    func beginRequest(with context: NSExtensionContext) {
        let contextBox = UncheckedExtensionContext(value: context)
        Task {
            do {
                let record = try await extractRecord(from: contextBox.value.inputItems)
                try write(record)
                contextBox.value.completeRequest(returningItems: [], completionHandler: nil)
            } catch {
                contextBox.value.cancelRequest(withError: error)
            }
        }
    }

    private func extractRecord(from items: [Any]) async throws -> ShareInboxRecord {
        let extensionItems = items.compactMap { $0 as? NSExtensionItem }
        var loadError: Error?
        for item in extensionItems {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    do {
                        if let value = try await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL,
                           Self.isWebURL(value) {
                            return ShareInboxRecord(url: value, title: item.attributedTitle?.string, selectedText: item.attributedContentText?.string)
                        }
                    } catch { loadError = error }
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    do {
                        if let value = try await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
                           let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
                           Self.isWebURL(url) {
                            return ShareInboxRecord(url: url, title: item.attributedTitle?.string)
                        }
                    } catch { loadError = error }
                }
            }
        }
        if let loadError { throw loadError }
        throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "Share an HTTP or HTTPS article URL with Crosscurrent."])
    }

    private static func isWebURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            && url.host?.isEmpty == false && url.user == nil && url.password == nil
    }

    private func write(_ record: ShareInboxRecord) throws {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.chonghanqin.crosscurrent") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let inbox = container.appending(path: "Inbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let destination = inbox.appending(path: "\(record.id.uuidString.lowercased()).json")
        let data = try JSONEncoder().encode(record)
        try data.write(to: destination, options: [.atomic, .completeFileProtection])
    }
}

private struct UncheckedExtensionContext: @unchecked Sendable {
    var value: NSExtensionContext
}
