import Darwin
import Foundation

@objc public protocol CrosscurrentXPCService {
    func handle(_ envelope: CCIPCEnvelope, withReply reply: @escaping (CCIPCEnvelope?, NSError?) -> Void)
}

public struct CCCodeSigningIdentity: Codable, Hashable, Sendable {
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

public enum CCSigningEnvironment {
    public static var currentMode: CCCodeSigningIdentity.SigningMode {
        #if DEBUG
        .appleDevelopment
        #else
        .developerID
        #endif
    }
}

public enum CrosscurrentIPCInterface {
    public static func make() -> NSXPCInterface {
        let interface = NSXPCInterface(with: CrosscurrentXPCService.self)
        let envelopeClasses = NSSet(object: CCIPCEnvelope.self) as! Set<AnyHashable>
        let errorClasses = NSSet(object: NSError.self) as! Set<AnyHashable>
        interface.setClasses(
            envelopeClasses,
            for: #selector(CrosscurrentXPCService.handle(_:withReply:)),
            argumentIndex: 0,
            ofReply: false
        )
        interface.setClasses(
            envelopeClasses,
            for: #selector(CrosscurrentXPCService.handle(_:withReply:)),
            argumentIndex: 0,
            ofReply: true
        )
        interface.setClasses(
            errorClasses,
            for: #selector(CrosscurrentXPCService.handle(_:withReply:)),
            argumentIndex: 1,
            ofReply: true
        )
        return interface
    }
}

public final class SecureXPCListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    public typealias ServiceFactory = @Sendable () -> CrosscurrentXPCService

    private let expectedPeers: [CCCodeSigningIdentity]
    private let serviceFactory: ServiceFactory
    private let requiredEffectiveUser: uid_t

    public init(expectedPeer: CCCodeSigningIdentity, requiredEffectiveUser: uid_t = geteuid(), serviceFactory: @escaping ServiceFactory) {
        self.expectedPeers = [expectedPeer]
        self.requiredEffectiveUser = requiredEffectiveUser
        self.serviceFactory = serviceFactory
    }

    public init(expectedPeers: [CCCodeSigningIdentity], requiredEffectiveUser: uid_t = geteuid(), serviceFactory: @escaping ServiceFactory) {
        precondition(!expectedPeers.isEmpty, "An XPC listener must authenticate at least one exact peer identity.")
        self.expectedPeers = expectedPeers
        self.requiredEffectiveUser = requiredEffectiveUser
        self.serviceFactory = serviceFactory
    }

    public func listener(_: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == requiredEffectiveUser else { return false }
        let requirement = expectedPeers.map { "(\($0.requirement))" }.joined(separator: " or ")
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = CrosscurrentIPCInterface.make()
        connection.exportedObject = serviceFactory()
        connection.resume()
        return true
    }
}

public enum SecureXPCConnectionFactory {
    public static func machService(name: String, expectedPeer: CCCodeSigningIdentity) -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: name)
        connection.setCodeSigningRequirement(expectedPeer.requirement)
        connection.remoteObjectInterface = CrosscurrentIPCInterface.make()
        return connection
    }
}

public actor CrosscurrentXPCClient {
    private let connection: NSXPCConnection

    public init(machServiceName: String, expectedPeer: CCCodeSigningIdentity) {
        connection = SecureXPCConnectionFactory.machService(name: machServiceName, expectedPeer: expectedPeer)
        connection.resume()
    }

    public func send<T: Encodable, Response: Decodable>(
        _ value: T,
        messageType: CCIPCMessageType,
        response: Response.Type,
        idempotencyKey: String,
        traceID: UUID = UUID()
    ) async throws -> Response {
        let payload = try CCIPCPayloadCodec.encode(value)
        let envelope = try CCIPCEnvelope(messageType: messageType, traceID: traceID, idempotencyKey: idempotencyKey, payload: payload)
        let reply = try await send(envelope)
        return try CCIPCPayloadCodec.decode(response, from: reply.payload)
    }

    public func send(_ envelope: CCIPCEnvelope) async throws -> CCIPCEnvelope {
        try await withCheckedThrowingContinuation { continuation in
            let box = XPCContinuationBox(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in box.resume(throwing: error) }
            guard let service = proxy as? CrosscurrentXPCService else {
                box.resume(throwing: CCIPCError.invalidPayload)
                return
            }
            service.handle(envelope) { reply, error in
                if let error { box.resume(throwing: error) }
                else if let reply { box.resume(returning: reply) }
                else { box.resume(throwing: CCIPCError.invalidPayload) }
            }
        }
    }

    public func invalidate() { connection.invalidate() }
}

private final class XPCContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CCIPCEnvelope, Error>?

    init(_ continuation: CheckedContinuation<CCIPCEnvelope, Error>) { self.continuation = continuation }

    func resume(returning value: CCIPCEnvelope) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<CCIPCEnvelope, Error>? {
        lock.lock(); defer { lock.unlock() }
        let value = continuation
        continuation = nil
        return value
    }
}
