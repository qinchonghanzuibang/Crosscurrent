import CryptoKit
import Foundation
import FeedFlowIPC
import Testing

private struct ExamplePayload: Codable, Equatable {
    var value: String
    var count: Int
}

@Test func secureEnvelopeRoundTripsVersionedData() throws {
    let input = ExamplePayload(value: "跨进程", count: 7)
    let payload = try FFIPCPayloadCodec.encode(input)
    let envelope = try FFIPCEnvelope(messageType: .enqueueJob, idempotencyKey: "job:one", payload: payload)
    let archived = try NSKeyedArchiver.archivedData(withRootObject: envelope, requiringSecureCoding: true)
    let unarchived = try NSKeyedUnarchiver.unarchivedObject(ofClass: FFIPCEnvelope.self, from: archived)
    let decoded = try #require(unarchived)
    #expect(decoded.type == .enqueueJob)
    #expect(decoded.idempotencyKey == "job:one")
    #expect(try FFIPCPayloadCodec.decode(ExamplePayload.self, from: decoded.payload) == input)
}

@Test func oversizedInlinePayloadIsRejected() {
    #expect(throws: FFIPCError.self) {
        _ = try FFIPCEnvelope(
            messageType: .browserResult,
            idempotencyKey: "oversized",
            payload: Data(repeating: 0, count: FFIPCEnvelope.maximumInlinePayloadBytes + 1)
        )
    }
}

@Test func stagedCapabilityValidatesSizeDigestAndScope() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "FeedFlowIPCTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let data = Data("safe staged payload".utf8)
    let file = root.appending(path: "request.bin")
    try data.write(to: file)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let capability = FFStagedFileCapability(relativePath: "request.bin", expectedSize: Int64(data.count), sha256: digest, expiresAt: .now.addingTimeInterval(60))
    #expect(try capability.consume(from: root) == data)
    #expect(FileManager.default.fileExists(atPath: file.path) == false)

    let escaped = FFStagedFileCapability(relativePath: "../escape", expectedSize: 0, sha256: digest, expiresAt: .now.addingTimeInterval(60))
    #expect(throws: FFIPCError.invalidStagedPath) { try escaped.consume(from: root) }
}

@Test func signingRequirementPinsTeamAndBundle() {
    let identity = FFCodeSigningIdentity(teamID: "ABCDE12345", bundleID: "com.chonghanqin.feedflow.agent", signingMode: .developerID)
    #expect(identity.requirement.contains("ABCDE12345"))
    #expect(identity.requirement.contains("com.chonghanqin.feedflow.agent"))
    #expect(identity.requirement.contains("anchor apple generic"))
}

@Test func browserListenerPeerAllowlistKeepsIdentitiesExact() {
    let app = FFCodeSigningIdentity(teamID: "ABCDE12345", bundleID: "com.chonghanqin.feedflow", signingMode: .developerID)
    let agent = FFCodeSigningIdentity(teamID: "ABCDE12345", bundleID: "com.chonghanqin.feedflow.agent", signingMode: .developerID)
    let combined = [app, agent].map { "(\($0.requirement))" }.joined(separator: " or ")
    #expect(combined.contains("identifier \"com.chonghanqin.feedflow\""))
    #expect(combined.contains("identifier \"com.chonghanqin.feedflow.agent\""))
    #expect(combined.contains(" or "))
    #expect(combined.contains("certificate leaf[subject.OU] = \"ABCDE12345\""))
}
