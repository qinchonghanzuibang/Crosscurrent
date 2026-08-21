import AppKit
import FeedFlowBrowser
import FeedFlowConnectors
import FeedFlowIPC
import Foundation
import WebKit

@main
enum FeedFlowBrowserWorkerMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let runtime = BrowserWorkerRuntime()
        runtime.start()
        application.run()
    }
}

@MainActor
final class BrowserWorkerRuntime: NSObject, @unchecked Sendable {
    private var listener: NSXPCListener?
    private var delegate: SecureXPCListenerDelegate?
    private let owner = BrowserSessionOwner()

    func start() {
        let teamID = Bundle.main.object(forInfoDictionaryKey: "FeedFlowTeamIdentifier") as? String ?? "TEAMID_REQUIRED"
        let peers = [
            FFCodeSigningIdentity(teamID: teamID, bundleID: "com.chonghanqin.feedflow", signingMode: FFSigningEnvironment.currentMode),
            FFCodeSigningIdentity(teamID: teamID, bundleID: "com.chonghanqin.feedflow.agent", signingMode: FFSigningEnvironment.currentMode),
        ]
        let owner = self.owner
        let delegate = SecureXPCListenerDelegate(expectedPeers: peers) { BrowserControlService(owner: owner) }
        let listener = NSXPCListener(machServiceName: "com.chonghanqin.feedflow.browser.control")
        listener.delegate = delegate
        listener.resume()
        self.delegate = delegate
        self.listener = listener
    }
}

final class BrowserControlService: NSObject, FeedFlowXPCService, @unchecked Sendable {
    private let owner: BrowserSessionOwner
    init(owner: BrowserSessionOwner) { self.owner = owner }

    func handle(_ envelope: FFIPCEnvelope, withReply reply: @escaping (FFIPCEnvelope?, NSError?) -> Void) {
        let replyBox = BrowserReply(invoke: reply)
        Task { @MainActor in
            do {
                guard envelope.type == .browserRequest else { throw FFIPCError.invalidPayload }
                let request = try FFIPCPayloadCodec.decode(BrowserWorkerRequest.self, from: envelope.payload)
                let response = try await self.handle(request)
                let payload = try FFIPCPayloadCodec.encode(response)
                replyBox.invoke(try FFIPCEnvelope(messageType: .browserResult, requestID: envelope.requestID, traceID: envelope.traceID, idempotencyKey: envelope.idempotencyKey, payload: payload), nil)
            } catch { replyBox.invoke(nil, error as NSError) }
        }
    }

    @MainActor
    private func handle(_ request: BrowserWorkerRequest) async throws -> BrowserWorkerResponse {
        switch request {
        case let .navigate(navigation):
            let webView = try await owner.navigate(navigation)
            let htmlValue = try await webView.callAsyncJavaScript("return document.documentElement.outerHTML", arguments: [:], in: nil, contentWorld: .world(name: "FeedFlowSnapshot"))
            guard let html = htmlValue as? String else { throw BrowserWorkerError.invalidResult }
            let sanitized = try StaticHTMLPreprocessor.conservativeSanitize(html)
            let finalURL = webView.url ?? navigation.url
            return .page(BrowserPageSnapshot(finalURL: finalURL, title: webView.title ?? sanitized.title, sanitizedHTML: sanitized.sanitizedHTML, plainText: sanitized.plainText))
        case let .authenticate(platform, accountID, presentsWindow):
            guard presentsWindow else { throw ConnectorError.interactionRequired }
            let profile = BrowserProfile(id: accountID.rawValue, displayName: platform.rawValue)
            owner.presentLogin(profile: profile, url: BrowserCreatorDOMExtractor.loginURL(for: platform))
            NSApplication.shared.activate(ignoringOtherApps: true)
            return .acknowledged
        case let .discover(discovery):
            guard let accountID = discovery.accountID else { throw ConnectorError.authenticationRequired }
            let navigation = BrowserNavigationRequest(profileID: accountID.rawValue, url: discovery.inputURL)
            let webView = try await owner.navigate(navigation, profileName: discovery.platform.rawValue)
            return .creatorIdentity(try await BrowserCreatorDOMExtractor.discover(platform: discovery.platform, in: webView))
        case let .refresh(refresh):
            let navigation = BrowserNavigationRequest(profileID: refresh.accountID.rawValue, url: refresh.profileURL)
            let webView = try await owner.navigate(navigation, profileName: refresh.platform.rawValue)
            return .refreshPage(try await BrowserCreatorDOMExtractor.refresh(platform: refresh.platform, cursor: refresh.cursor, in: webView))
        case let .health(_, accountID):
            guard let accountID else { return .health(.authenticationRequired) }
            return .health(owner.health(profileID: accountID.rawValue))
        case let .disconnect(_, accountID):
            await owner.disconnect(profileID: accountID.rawValue)
            return .acknowledged
        }
    }
}

private struct BrowserReply: @unchecked Sendable {
    var invoke: (FFIPCEnvelope?, NSError?) -> Void
}
