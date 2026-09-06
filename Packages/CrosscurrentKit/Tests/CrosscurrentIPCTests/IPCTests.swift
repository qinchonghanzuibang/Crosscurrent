import CryptoKit
import Foundation
import CrosscurrentIPC
import Testing

private struct ExamplePayload: Codable, Equatable {
    var value: String
    var count: Int
}

@Test func secureEnvelopeRoundTripsVersionedData() throws {
    let input = ExamplePayload(value: "跨进程", count: 7)
    let payload = try CCIPCPayloadCodec.encode(input)
    let envelope = try CCIPCEnvelope(messageType: .enqueueJob, idempotencyKey: "job:one", payload: payload)
    let archived = try NSKeyedArchiver.archivedData(withRootObject: envelope, requiringSecureCoding: true)
    let unarchived = try NSKeyedUnarchiver.unarchivedObject(ofClass: CCIPCEnvelope.self, from: archived)
    let decoded = try #require(unarchived)
    #expect(decoded.type == .enqueueJob)
    #expect(decoded.idempotencyKey == "job:one")
    #expect(try CCIPCPayloadCodec.decode(ExamplePayload.self, from: decoded.payload) == input)
}

@Test func oversizedInlinePayloadIsRejected() {
    #expect(throws: CCIPCError.self) {
        _ = try CCIPCEnvelope(
            messageType: .browserResult,
            idempotencyKey: "oversized",
            payload: Data(repeating: 0, count: CCIPCEnvelope.maximumInlinePayloadBytes + 1)
        )
    }
}

@Test func stagedCapabilityValidatesSizeDigestAndScope() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "CrosscurrentIPCTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let data = Data("safe staged payload".utf8)
    let file = root.appending(path: "request.bin")
    try data.write(to: file)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let capability = CCStagedFileCapability(relativePath: "request.bin", expectedSize: Int64(data.count), sha256: digest, expiresAt: .now.addingTimeInterval(60))
    #expect(try capability.consume(from: root) == data)
    #expect(FileManager.default.fileExists(atPath: file.path) == false)

    let escaped = CCStagedFileCapability(relativePath: "../escape", expectedSize: 0, sha256: digest, expiresAt: .now.addingTimeInterval(60))
    #expect(throws: CCIPCError.invalidStagedPath) { try escaped.consume(from: root) }
}

@Test func signingRequirementPinsTeamAndBundle() {
    let identity = CCCodeSigningIdentity(teamID: "ABCDE12345", bundleID: "com.chonghanqin.crosscurrent.agent", signingMode: .developerID)
    #expect(identity.requirement.contains("ABCDE12345"))
    #expect(identity.requirement.contains("com.chonghanqin.crosscurrent.agent"))
    #expect(identity.requirement.contains("anchor apple generic"))
}

@Test func browserListenerPeerAllowlistKeepsIdentitiesExact() {
    let app = CCCodeSigningIdentity(teamID: "ABCDE12345", bundleID: "com.chonghanqin.crosscurrent", signingMode: .developerID)
    let agent = CCCodeSigningIdentity(teamID: "ABCDE12345", bundleID: "com.chonghanqin.crosscurrent.agent", signingMode: .developerID)
    let combined = [app, agent].map { "(\($0.requirement))" }.joined(separator: " or ")
    #expect(combined.contains("identifier \"com.chonghanqin.crosscurrent\""))
    #expect(combined.contains("identifier \"com.chonghanqin.crosscurrent.agent\""))
    #expect(combined.contains(" or "))
    #expect(combined.contains("certificate leaf[subject.OU] = \"ABCDE12345\""))
}

@Test func stagedCapabilityRejectsSymlinkedAncestorsAndHardLinks() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "CrosscurrentIPCLinks-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let staging = root.appending(path: "staging", directoryHint: .isDirectory)
    let outside = root.appending(path: "outside", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let data = Data("outside payload".utf8)
    let file = outside.appending(path: "payload.bin")
    try data.write(to: file)
    try FileManager.default.createSymbolicLink(at: staging.appending(path: "linked"), withDestinationURL: outside)
    try FileManager.default.linkItem(at: file, to: staging.appending(path: "hardlinked.bin"))
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    for relativePath in ["linked/payload.bin", "hardlinked.bin", "/outside/payload.bin", "../outside/payload.bin"] {
        let capability = CCStagedFileCapability(relativePath: relativePath, expectedSize: Int64(data.count), sha256: digest, expiresAt: .now.addingTimeInterval(60))
        #expect(throws: CCIPCError.invalidStagedPath) { try capability.consume(from: staging) }
    }
    #expect(try Data(contentsOf: file) == data)
}
