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
        for item in extensionItems {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let value = try await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                    return ShareInboxRecord(url: value, title: item.attributedTitle?.string, selectedText: item.attributedContentText?.string)
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let value = try await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
                   let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    return ShareInboxRecord(url: url, title: item.attributedTitle?.string)
                }
            }
        }
        throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "No shareable URL was supplied."])
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
