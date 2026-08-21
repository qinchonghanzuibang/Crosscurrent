import Darwin
import Foundation

@objc public protocol FeedFlowXPCService {
    func handle(_ envelope: FFIPCEnvelope, withReply reply: @escaping (FFIPCEnvelope?, NSError?) -> Void)
}

public struct FFCodeSigningIdentity: Codable, Hashable, Sendable {
    public var teamID: String
    public var bundleID: String
    public var signingMode: SigningMode

    public enum SigningMode: String, Codable, Sendable {
        case developerID
        case appleDevelopment
    }

    public init(teamID: String, bundleID: String, signingMode: SigningMode) {
        self.teamID = teamID
        self.bundleID = bundleID
        self.signingMode = signingMode
    }

    public var requirement: String {
        let certificateRequirement: String
        switch signingMode {
        case .developerID:
            certificateRequirement = "certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        case .appleDevelopment:
            certificateRequirement = "certificate leaf[field.1.2.840.113635.100.6.1.12] exists"
        }
        return "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(teamID)\" and \(certificateRequirement)"
    }
}

public enum FFSigningEnvironment {
    public static var currentMode: FFCodeSigningIdentity.SigningMode {
        #if DEBUG
        .appleDevelopment
        #else
        .developerID
        #endif
    }
}

public enum FeedFlowIPCInterface {
    public static func make() -> NSXPCInterface {
        let interface = NSXPCInterface(with: FeedFlowXPCService.self)
        let envelopeClasses = NSSet(object: FFIPCEnvelope.self) as! Set<AnyHashable>
        let errorClasses = NSSet(object: NSError.self) as! Set<AnyHashable>
        interface.setClasses(
            envelopeClasses,
            for: #selector(FeedFlowXPCService.handle(_:withReply:)),
            argumentIndex: 0,
            ofReply: false
        )
        interface.setClasses(
            envelopeClasses,
            for: #selector(FeedFlowXPCService.handle(_:withReply:)),
            argumentIndex: 0,
            ofReply: true
        )
        interface.setClasses(
            errorClasses,
            for: #selector(FeedFlowXPCService.handle(_:withReply:)),
            argumentIndex: 1,
            ofReply: true
        )
        return interface
    }
}

public final class SecureXPCListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    public typealias ServiceFactory = @Sendable () -> FeedFlowXPCService

    private let expectedPeers: [FFCodeSigningIdentity]
    private let serviceFactory: ServiceFactory
    private let requiredEffectiveUser: uid_t

    public init(expectedPeer: FFCodeSigningIdentity, requiredEffectiveUser: uid_t = geteuid(), serviceFactory: @escaping ServiceFactory) {
        self.expectedPeers = [expectedPeer]
        self.requiredEffectiveUser = requiredEffectiveUser
        self.serviceFactory = serviceFactory
    }

    public init(expectedPeers: [FFCodeSigningIdentity], requiredEffectiveUser: uid_t = geteuid(), serviceFactory: @escaping ServiceFactory) {
        precondition(!expectedPeers.isEmpty, "An XPC listener must authenticate at least one exact peer identity.")
        self.expectedPeers = expectedPeers
        self.requiredEffectiveUser = requiredEffectiveUser
        self.serviceFactory = serviceFactory
    }

    public func listener(_: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == requiredEffectiveUser else { return false }
        let requirement = expectedPeers.map { "(\($0.requirement))" }.joined(separator: " or ")
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = FeedFlowIPCInterface.make()
        connection.exportedObject = serviceFactory()
        connection.resume()
        return true
    }
}

public enum SecureXPCConnectionFactory {
    public static func machService(name: String, expectedPeer: FFCodeSigningIdentity) -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: name)
        connection.setCodeSigningRequirement(expectedPeer.requirement)
        connection.remoteObjectInterface = FeedFlowIPCInterface.make()
        return connection
    }
}

public actor FeedFlowXPCClient {
    private let connection: NSXPCConnection

    public init(machServiceName: String, expectedPeer: FFCodeSigningIdentity) {
        connection = SecureXPCConnectionFactory.machService(name: machServiceName, expectedPeer: expectedPeer)
        connection.resume()
    }

    public func send<T: Encodable, Response: Decodable>(
        _ value: T,
        messageType: FFIPCMessageType,
        response: Response.Type,
        idempotencyKey: String,
        traceID: UUID = UUID()
    ) async throws -> Response {
        let payload = try FFIPCPayloadCodec.encode(value)
        let envelope = try FFIPCEnvelope(messageType: messageType, traceID: traceID, idempotencyKey: idempotencyKey, payload: payload)
        let reply = try await send(envelope)
        return try FFIPCPayloadCodec.decode(response, from: reply.payload)
    }

    public func send(_ envelope: FFIPCEnvelope) async throws -> FFIPCEnvelope {
        try await withCheckedThrowingContinuation { continuation in
            let box = XPCContinuationBox(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in box.resume(throwing: error) }
            guard let service = proxy as? FeedFlowXPCService else {
                box.resume(throwing: FFIPCError.invalidPayload)
                return
            }
            service.handle(envelope) { reply, error in
                if let error { box.resume(throwing: error) }
                else if let reply { box.resume(returning: reply) }
                else { box.resume(throwing: FFIPCError.invalidPayload) }
            }
        }
    }

    public func invalidate() { connection.invalidate() }
}

private final class XPCContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<FFIPCEnvelope, Error>?

    init(_ continuation: CheckedContinuation<FFIPCEnvelope, Error>) { self.continuation = continuation }

    func resume(returning value: FFIPCEnvelope) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<FFIPCEnvelope, Error>? {
        lock.lock(); defer { lock.unlock() }
        let value = continuation
        continuation = nil
        return value
    }
}
