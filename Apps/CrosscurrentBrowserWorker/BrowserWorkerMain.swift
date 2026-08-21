import AppKit
import CrosscurrentBrowser
import CrosscurrentConnectors
import CrosscurrentIPC
import Foundation
import WebKit

@main
enum CrosscurrentBrowserWorkerMain {
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
        let teamID = Bundle.main.object(forInfoDictionaryKey: "CrosscurrentTeamIdentifier") as? String ?? "TEAMID_REQUIRED"
        let peers = [
            CCCodeSigningIdentity(teamID: teamID, bundleID: "com.chonghanqin.crosscurrent", signingMode: CCSigningEnvironment.currentMode),
            CCCodeSigningIdentity(teamID: teamID, bundleID: "com.chonghanqin.crosscurrent.agent", signingMode: CCSigningEnvironment.currentMode),
        ]
        let owner = self.owner
        let delegate = SecureXPCListenerDelegate(expectedPeers: peers) { BrowserControlService(owner: owner) }
        let listener = NSXPCListener(machServiceName: "com.chonghanqin.crosscurrent.browser.control")
        listener.delegate = delegate
        listener.resume()
        self.delegate = delegate
        self.listener = listener
    }
}

final class BrowserControlService: NSObject, CrosscurrentXPCService, @unchecked Sendable {
    private let owner: BrowserSessionOwner
    init(owner: BrowserSessionOwner) { self.owner = owner }

    func handle(_ envelope: CCIPCEnvelope, withReply reply: @escaping (CCIPCEnvelope?, NSError?) -> Void) {
        let replyBox = BrowserReply(invoke: reply)
        Task { @MainActor in
            do {
                guard envelope.type == .browserRequest else { throw CCIPCError.invalidPayload }
                let request = try CCIPCPayloadCodec.decode(BrowserWorkerRequest.self, from: envelope.payload)
                let response = try await self.handle(request)
                let payload = try CCIPCPayloadCodec.encode(response)
                replyBox.invoke(try CCIPCEnvelope(messageType: .browserResult, requestID: envelope.requestID, traceID: envelope.traceID, idempotencyKey: envelope.idempotencyKey, payload: payload), nil)
            } catch { replyBox.invoke(nil, error as NSError) }
        }
    }

    @MainActor
    private func handle(_ request: BrowserWorkerRequest) async throws -> BrowserWorkerResponse {
        switch request {
        case let .navigate(navigation):
            let webView = try await owner.navigate(navigation)
            let htmlValue = try await webView.callAsyncJavaScript("return document.documentElement.outerHTML", arguments: [:], in: nil, contentWorld: .world(name: "CrosscurrentSnapshot"))
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
        case let .capture(capture):
            let navigation = BrowserNavigationRequest(profileID: capture.accountID.rawValue, url: capture.url)
            let webView = try await owner.navigate(navigation, profileName: capture.platform.rawValue)
            let value = try await webView.callAsyncJavaScript(
                """
                const counts = {};
                for (const child of document.body?.children || []) {
                  const tag = String(child.tagName || '').toLowerCase();
                  if (tag) counts[tag] = (counts[tag] || 0) + 1;
                }
                const origins = [...new Set(performance.getEntriesByType('resource').map(entry => {
                  try { return new URL(entry.name).origin; } catch (_) { return null; }
                }).filter(Boolean))].sort().slice(0, 100);
                return JSON.stringify({counts, origins});
                """,
                arguments: [:],
                in: nil,
                contentWorld: .world(name: "CrosscurrentCapture")
            )
            guard let json = value as? String,
                  let data = json.data(using: .utf8),
                  let shape = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw BrowserWorkerError.invalidResult }
            var safeComponents = URLComponents(url: webView.url ?? capture.url, resolvingAgainstBaseURL: false)
            safeComponents?.query = nil
            safeComponents?.fragment = nil
            guard let safeURL = safeComponents?.url else { throw BrowserWorkerError.invalidResult }
            let rawCounts = shape["counts"] as? [String: Any] ?? [:]
            let counts = rawCounts.compactMapValues { ($0 as? NSNumber)?.intValue }
            let origins = (shape["origins"] as? [String] ?? []).filter { $0.hasPrefix("https://") }
            return .captureFixture(BrowserPlatformCaptureFixture(
                schemaVersion: capture.schemaVersion,
                platform: capture.platform,
                kind: capture.kind,
                finalURLWithoutQuery: safeURL,
                title: webView.title ?? "",
                topLevelElementCounts: counts,
                resourceOrigins: origins,
                capturedAt: .now
            ))
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
    var invoke: (CCIPCEnvelope?, NSError?) -> Void
}
