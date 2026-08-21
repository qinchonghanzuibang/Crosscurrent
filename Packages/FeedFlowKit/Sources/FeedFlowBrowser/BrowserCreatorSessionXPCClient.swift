import FeedFlowConnectors
import FeedFlowDomain
import FeedFlowIPC
import CryptoKit
import Foundation

public actor BrowserCreatorSessionXPCClient: BrowserCreatorSessionClient {
    private let client: FeedFlowXPCClient

    public init(teamID: String, signingMode: FFCodeSigningIdentity.SigningMode) {
        let peer = FFCodeSigningIdentity(teamID: teamID, bundleID: "com.chonghanqin.feedflow.browser", signingMode: signingMode)
        client = FeedFlowXPCClient(machServiceName: "com.chonghanqin.feedflow.browser.control", expectedPeer: peer)
    }

    public func authenticate(platform: AuthenticatedCreatorPlatform, accountID: ConnectorAccountID, allowsInteraction: Bool) async throws {
        guard allowsInteraction else { throw ConnectorError.interactionRequired }
        let response = try await request(.authenticate(platform: platform, accountID: accountID, presentsWindow: true), key: "browser-auth:\(platform.rawValue):\(accountID)")
        guard response == .acknowledged else { throw BrowserWorkerError.invalidResult }
    }

    public func discover(_ requestValue: BrowserCreatorDiscoveryRequest) async throws -> BrowserCreatorIdentity {
        let response = try await request(.discover(requestValue), key: "browser-discover:\(requestValue.platform.rawValue):\(requestValue.inputURL.absoluteString)")
        guard case let .creatorIdentity(identity) = response else { throw BrowserWorkerError.invalidResult }
        return identity
    }

    public func refresh(_ requestValue: BrowserCreatorRefreshRequest) async throws -> ConnectorRefreshPage {
        let cursorDigest = requestValue.cursor.map { cursor in
            SHA256.hash(data: cursor.value).map { String(format: "%02x", $0) }.joined()
        } ?? "initial"
        let response = try await request(.refresh(requestValue), key: "browser-refresh:\(requestValue.platform.rawValue):\(requestValue.endpointExternalID):\(cursorDigest)")
        guard case let .refreshPage(page) = response else { throw BrowserWorkerError.invalidResult }
        return page
    }

    public func health(platform: AuthenticatedCreatorPlatform, accountID: ConnectorAccountID?) async -> ConnectorHealth {
        do {
            let response = try await request(.health(platform: platform, accountID: accountID), key: "browser-health:\(platform.rawValue):\(accountID?.description ?? "none")")
            guard case let .health(health) = response else { return .error }
            return health
        } catch {
            return .temporarilyUnavailable
        }
    }

    public func disconnect(platform: AuthenticatedCreatorPlatform, accountID: ConnectorAccountID) async throws {
        let response = try await request(.disconnect(platform: platform, accountID: accountID), key: "browser-disconnect:\(platform.rawValue):\(accountID)")
        guard response == .acknowledged else { throw BrowserWorkerError.invalidResult }
    }

    public func navigate(profileID: UUID, url: URL, presentsWindow: Bool = true) async throws -> BrowserPageSnapshot {
        let navigation = BrowserNavigationRequest(profileID: profileID, url: url, presentsWindow: presentsWindow)
        let response = try await request(.navigate(navigation), key: "browser-navigate:\(profileID.uuidString.lowercased()):\(url.absoluteString)")
        guard case let .page(page) = response else { throw BrowserWorkerError.invalidResult }
        return page
    }

    private func request(_ request: BrowserWorkerRequest, key: String) async throws -> BrowserWorkerResponse {
        try await client.send(request, messageType: .browserRequest, response: BrowserWorkerResponse.self, idempotencyKey: key)
    }
}
