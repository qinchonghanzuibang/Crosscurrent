import AppKit
import CrosscurrentConnectors
import CrosscurrentDomain
import Foundation
import WebKit

@MainActor
public final class BrowserSessionOwner: NSObject {
    private var webViews: [UUID: WKWebView] = [:]
    private var windows: [UUID: NSWindow] = [:]
    private let operationGate = BrowserProfileOperationGate()

    public override init() { super.init() }

    public func webView(for profile: BrowserProfile) -> WKWebView {
        if let existing = webViews[profile.id] { return existing }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: profile.id)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.customUserAgent = "CrosscurrentBrowserWorker/1"
        webViews[profile.id] = view
        return view
    }

    public func presentLogin(profile: BrowserProfile, url: URL) {
        let webView = webView(for: profile)
        present(profile: profile, webView: webView)
        webView.load(URLRequest(url: url))
    }

    private func present(profile: BrowserProfile, webView: WKWebView) {
        let window: NSWindow
        if let existing = windows[profile.id] {
            window = existing
        } else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = profile.displayName
            window.contentView = webView
            window.center()
            windows[profile.id] = window
        }
        window.makeKeyAndOrderFront(nil)
    }

    public func navigate(_ request: BrowserNavigationRequest, profileName: String = "Authenticated Source") async throws -> WKWebView {
        await operationGate.acquire(request.profileID)
        do {
            let result = try await navigateWhileAcquired(request, profileName: profileName)
            await operationGate.release(request.profileID)
            return result
        } catch {
            await operationGate.release(request.profileID)
            throw error
        }
    }

    private func navigateWhileAcquired(_ request: BrowserNavigationRequest, profileName: String) async throws -> WKWebView {
        let profile = BrowserProfile(id: request.profileID, displayName: profileName)
        let webView = webView(for: profile)
        if request.presentsWindow { present(profile: profile, webView: webView) }
        try await NavigationWaiter.load(URLRequest(url: request.url), in: webView)
        return webView
    }

    public func close(profileID: UUID) {
        windows[profileID]?.close()
        windows[profileID] = nil
        webViews[profileID]?.stopLoading()
        webViews[profileID] = nil
    }

    public func disconnect(profileID: UUID) async {
        let store = webViews[profileID]?.configuration.websiteDataStore ?? WKWebsiteDataStore(forIdentifier: profileID)
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { continuation in
            store.removeData(ofTypes: dataTypes, modifiedSince: .distantPast) { continuation.resume() }
        }
        close(profileID: profileID)
    }

    public func health(profileID: UUID) -> ConnectorHealth {
        guard let webView = webViews[profileID] else { return .temporarilyUnavailable }
        guard !webView.isLoading else { return .syncing }
        guard let url = webView.url else { return .authenticationRequired }
        let value = url.absoluteString.lowercased()
        return value.contains("login") || value.contains("signin") ? .authenticationRequired : .healthy
    }
}

@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private weak var webView: WKWebView?
    private var timeoutTask: Task<Void, Never>?

    static func load(_ request: URLRequest, in webView: WKWebView) async throws {
        let waiter = NavigationWaiter()
        waiter.webView = webView
        webView.navigationDelegate = waiter
        try await withCheckedThrowingContinuation { continuation in
            waiter.continuation = continuation
            webView.load(request)
            waiter.timeoutTask = Task { @MainActor [weak waiter] in
                try? await Task.sleep(for: .seconds(45))
                guard !Task.isCancelled else { return }
                waiter?.fail(BrowserWorkerError.navigationFailed("Navigation timed out."))
            }
        }
        withExtendedLifetime(waiter) {}
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        timeoutTask?.cancel()
        continuation?.resume()
        continuation = nil
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        fail(BrowserWorkerError.navigationFailed(error.localizedDescription))
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        fail(BrowserWorkerError.navigationFailed(error.localizedDescription))
    }

    private func fail(_ error: Error) {
        timeoutTask?.cancel()
        webView?.stopLoading()
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

private actor BrowserProfileOperationGate {
    private var active: Set<UUID> = []
    private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(_ profileID: UUID) async {
        if active.insert(profileID).inserted { return }
        await withCheckedContinuation { continuation in waiters[profileID, default: []].append(continuation) }
    }

    func release(_ profileID: UUID) {
        if var queued = waiters[profileID], !queued.isEmpty {
            let next = queued.removeFirst()
            waiters[profileID] = queued.isEmpty ? nil : queued
            next.resume()
        } else {
            active.remove(profileID)
        }
    }
}
