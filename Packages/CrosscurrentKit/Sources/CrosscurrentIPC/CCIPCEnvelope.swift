import CryptoKit
import Foundation

public enum CCIPCMessageType: String, Codable, CaseIterable, Sendable {
    case health
    case enqueueJob
    case foregroundRefresh
    case browserRequest
    case browserResult
    case generationHint
    case stagedFile
    case error
}

@objc(CCIPCEnvelope)
public final class CCIPCEnvelope: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }
    public static let currentProtocolVersion = 1
    public static let maximumInlinePayloadBytes = 8 * 1_024 * 1_024

    @objc public let protocolVersion: Int
    @objc public let messageType: String
    @objc public let requestID: UUID
    @objc public let traceID: UUID
    @objc public let idempotencyKey: String
    @objc public let payload: Data

    public init(
        protocolVersion: Int = CCIPCEnvelope.currentProtocolVersion,
        messageType: CCIPCMessageType,
        requestID: UUID = UUID(),
        traceID: UUID = UUID(),
        idempotencyKey: String,
        payload: Data
    ) throws {
        guard protocolVersion > 0, protocolVersion <= Self.currentProtocolVersion else {
            throw CCIPCError.unsupportedProtocol(protocolVersion)
        }
        guard payload.count <= Self.maximumInlinePayloadBytes else {
            throw CCIPCError.payloadTooLarge(payload.count)
        }
        self.protocolVersion = protocolVersion
        self.messageType = messageType.rawValue
        self.requestID = requestID
        self.traceID = traceID
        self.idempotencyKey = idempotencyKey
        self.payload = payload
        super.init()
    }

    public required init?(coder: NSCoder) {
        let version = coder.decodeInteger(forKey: "protocolVersion")
        guard
            version > 0,
            version <= Self.currentProtocolVersion,
            let messageType = coder.decodeObject(of: NSString.self, forKey: "messageType") as String?,
            CCIPCMessageType(rawValue: messageType) != nil,
            let requestID = coder.decodeObject(of: NSUUID.self, forKey: "requestID") as UUID?,
            let traceID = coder.decodeObject(of: NSUUID.self, forKey: "traceID") as UUID?,
            let idempotencyKey = coder.decodeObject(of: NSString.self, forKey: "idempotencyKey") as String?,
            let payload = coder.decodeObject(of: NSData.self, forKey: "payload") as Data?,
            payload.count <= Self.maximumInlinePayloadBytes
        else { return nil }

        self.protocolVersion = version
        self.messageType = messageType
        self.requestID = requestID
        self.traceID = traceID
        self.idempotencyKey = idempotencyKey
        self.payload = payload
        super.init()
    }

    public func encode(with coder: NSCoder) {
        coder.encode(protocolVersion, forKey: "protocolVersion")
        coder.encode(messageType as NSString, forKey: "messageType")
        coder.encode(requestID as NSUUID, forKey: "requestID")
        coder.encode(traceID as NSUUID, forKey: "traceID")
        coder.encode(idempotencyKey as NSString, forKey: "idempotencyKey")
        coder.encode(payload as NSData, forKey: "payload")
    }

    public var type: CCIPCMessageType { CCIPCMessageType(rawValue: messageType)! }
}

public enum CCIPCError: LocalizedError, Equatable {
    case unsupportedProtocol(Int)
    case payloadTooLarge(Int)
    case invalidPayload
    case expiredCapability
    case invalidStagedPath
    case stagedFileSizeMismatch
    case stagedFileDigestMismatch
    case wrongEffectiveUser

    public var errorDescription: String? {
        switch self {
        case let .unsupportedProtocol(version): "Unsupported Crosscurrent IPC protocol version \(version)."
        case let .payloadTooLarge(size): "Crosscurrent IPC payload is too large (\(size) bytes)."
        case .invalidPayload: "Crosscurrent IPC payload could not be decoded."
        case .expiredCapability: "The staged-file capability has expired."
        case .invalidStagedPath: "The staged-file capability resolved outside its staging directory."
        case .stagedFileSizeMismatch: "The staged file has an unexpected size."
        case .stagedFileDigestMismatch: "The staged file failed SHA-256 validation."
        case .wrongEffectiveUser: "The XPC peer belongs to a different effective user."
        }
    }
}

public enum CCIPCPayloadCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= CCIPCEnvelope.maximumInlinePayloadBytes else {
            throw CCIPCError.payloadTooLarge(data.count)
        }
        do {
            return try PropertyListDecoder().decode(type, from: data)
        } catch {
            throw CCIPCError.invalidPayload
        }
    }
}

public struct CCStagedFileCapability: Codable, Hashable, Sendable {
    public static let maximumBytes: Int64 = 64 * 1_024 * 1_024

    public var relativePath: String
    public var expectedSize: Int64
    public var sha256: String
    public var expiresAt: Date
    public var nonce: UUID

    public init(relativePath: String, expectedSize: Int64, sha256: String, expiresAt: Date, nonce: UUID = UUID()) {
        self.relativePath = relativePath
        self.expectedSize = expectedSize
        self.sha256 = sha256
        self.expiresAt = expiresAt
        self.nonce = nonce
    }

    public func consume(from stagingRoot: URL, now: Date = .now, deleteAfterReading: Bool = true) throws -> Data {
        guard expiresAt > now else { throw CCIPCError.expiredCapability }
        guard expectedSize >= 0, expectedSize <= Self.maximumBytes else { throw CCIPCError.payloadTooLarge(Int(expectedSize)) }

        let root = stagingRoot.standardizedFileURL
        let candidate = root.appending(path: relativePath).standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPrefix), candidate.path != root.path else {
            throw CCIPCError.invalidStagedPath
        }
        let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CCIPCError.invalidStagedPath }
        guard Int64(values.fileSize ?? -1) == expectedSize else { throw CCIPCError.stagedFileSizeMismatch }
        let data = try Data(contentsOf: candidate, options: [.mappedIfSafe])
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256.lowercased() else { throw CCIPCError.stagedFileDigestMismatch }
        if deleteAfterReading { try FileManager.default.removeItem(at: candidate) }
        return data
    }
}
