import CryptoKit
import CrosscurrentDomain
import SwiftUI
import WebKit

public struct ReaderDocument: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var byline: String?
    public var publishedAt: Date?
    public var sanitizedHTML: String
    public var baseURL: URL?
    public var itemRevisionID: ItemRevisionID

    public init(id: String, title: String, byline: String? = nil, publishedAt: Date? = nil, sanitizedHTML: String, baseURL: URL? = nil, itemRevisionID: ItemRevisionID = ItemRevisionID()) {
        self.id = id
        self.title = title
        self.byline = byline
        self.publishedAt = publishedAt
        self.sanitizedHTML = sanitizedHTML
        self.baseURL = baseURL
        self.itemRevisionID = itemRevisionID
    }
}

public struct ReaderWebView: NSViewRepresentable {
    public var document: ReaderDocument
    @Binding private var selection: ReaderSelectionContext?
    @Binding private var activatedLink: URL?
    private var focusRequest: Int
    private var onEscape: () -> Void

    public init(
        document: ReaderDocument,
        selection: Binding<ReaderSelectionContext?> = .constant(nil),
        activatedLink: Binding<URL?> = .constant(nil),
        focusRequest: Int = 0,
        onEscape: @escaping () -> Void = {}
    ) {
        self.document = document
        _selection = selection
        _activatedLink = activatedLink
        self.focusRequest = focusRequest
        self.onEscape = onEscape
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection, activatedLink: $activatedLink)
    }

    public func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let world = WKContentWorld.world(name: "CrosscurrentReaderSelection")
        configuration.userContentController.add(context.coordinator, contentWorld: world, name: "crosscurrentSelection")
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.selectionScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: world
        ))
        let view = ReaderEscapeWebView(frame: .zero, configuration: configuration)
        view.onEscape = onEscape
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        (webView as? ReaderEscapeWebView)?.onEscape = onEscape
        context.coordinator.selection = $selection
        context.coordinator.activatedLink = $activatedLink
        context.coordinator.itemRevisionID = document.itemRevisionID
        context.coordinator.baseURL = document.baseURL
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { webView.window?.makeFirstResponder(webView) }
        }
        let loadIdentity = document.id + ":" + String(document.hashValue)
        guard context.coordinator.loadedIdentity != loadIdentity else { return }
        context.coordinator.loadedIdentity = loadIdentity
        context.coordinator.renderTask?.cancel()
        context.coordinator.renderTask = Task {
            let renderedHTML = await ReaderHTMLPreparer.prepare(document.sanitizedHTML)
            guard !Task.isCancelled, context.coordinator.loadedIdentity == loadIdentity else { return }
            webView.loadHTMLString(Self.page(document: document, renderedHTML: renderedHTML), baseURL: document.baseURL)
        }
    }

    private static func page(document: ReaderDocument, renderedHTML: String) -> String {
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        let metadata = [document.byline, document.publishedAt?.formatted(date: .abbreviated, time: .omitted)]
            .compactMap { $0 }.filter { !$0.isEmpty }.map(escaped).joined(separator: " · ")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="referrer" content="no-referrer">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data: blob: app-asset:; style-src 'unsafe-inline'; font-src data: app-asset:; connect-src 'none'; frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'">
        <style>
        :root{color-scheme:light dark;--accent:#b8472d;--muted:color-mix(in srgb,CanvasText 68%,Canvas);--rule:color-mix(in srgb,CanvasText 18%,Canvas);--code:color-mix(in srgb,CanvasText 7%,Canvas)}
        *{box-sizing:border-box}body{font:18px/1.72 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;padding:32px clamp(24px,7vw,72px) 72px;max-width:864px;margin:auto;color:CanvasText;background:Canvas;overflow-wrap:break-word}article{min-width:0}h1,h2,h3,h4,h5,h6{line-height:1.25;letter-spacing:-.018em;margin:1.65em 0 .65em;text-wrap:balance;scroll-margin-top:24px}h1{font-size:clamp(1.8rem,4.5vw,2.2rem);line-height:1.15;margin-top:.2em;margin-bottom:.55em}h2{font-size:1.5em}h3{font-size:1.22em}h4{font-size:1.1em}h5,h6{font-size:1em}h6{color:var(--muted)}.reader-metadata{font-size:14px;line-height:1.5;color:var(--muted);margin:0 0 2em}p,ul,ol,dl,blockquote,pre,table,figure{margin-top:1.05em;margin-bottom:1.05em}ul,ol{padding-left:1.45em}li>ul,li>ol{margin:.35em 0}dt{font-weight:650;margin-top:.8em}dd{margin:.2em 0 .8em 1.25em}a{color:var(--accent);text-decoration-thickness:.08em;text-underline-offset:.15em}a:focus-visible{outline:2px solid var(--accent);outline-offset:3px;border-radius:2px}hr{border:0;border-top:1px solid var(--rule);margin:2.4em 0}blockquote{border-left:3px solid var(--accent);margin-left:0;padding:.05em 0 .05em 1.1em;color:var(--muted)}code{font:0.88em/1.55 ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--code);padding:.12em .32em;border-radius:4px}pre{overflow:auto;white-space:pre;padding:1em 1.1em;background:var(--code);border:1px solid var(--rule);border-radius:8px;tab-size:4;-webkit-overflow-scrolling:touch}pre code{font-size:.88em;background:none;padding:0;border-radius:0}figure{margin-left:0;margin-right:0;text-align:center}img,svg{display:block;max-width:100%;height:auto;margin-left:auto;margin-right:auto}img{border-radius:6px;background:#fff}figcaption,caption{color:var(--muted);font-size:.88em;line-height:1.5}figcaption{max-width:68ch;margin:.65em auto 0}caption{text-align:left;padding:0 0 .7em}table{display:block;width:max-content;max-width:100%;overflow-x:auto;border-collapse:collapse;border-spacing:0;-webkit-overflow-scrolling:touch}th,td{min-width:8em;padding:.62em .75em;border:1px solid var(--rule);text-align:left;vertical-align:top}th{font-weight:650;background:var(--code)}math{font-size:1.04em}math[display="block"]{display:block;max-width:100%;overflow-x:auto;overflow-y:hidden;margin:1.25em 0;padding:.2em 0;text-align:center;-webkit-overflow-scrolling:touch}@media(prefers-color-scheme:dark){:root{--accent:#f39878}}@media(max-width:560px){body{font-size:17px;padding:24px 24px 56px}th,td{min-width:7em}}
        </style>
        </head><body><article><h1>\(escaped(document.title))</h1>\(metadata.isEmpty ? "" : "<p class=\"reader-metadata\">\(metadata)</p>")\(renderedHTML)</article></body></html>
        """
    }

    public final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        fileprivate var selection: Binding<ReaderSelectionContext?>
        fileprivate var activatedLink: Binding<URL?>
        fileprivate var itemRevisionID = ItemRevisionID()
        fileprivate var focusRequest = 0
        fileprivate var loadedIdentity: String?
        fileprivate var renderTask: Task<Void, Never>?
        fileprivate var baseURL: URL?

        fileprivate init(selection: Binding<ReaderSelectionContext?>, activatedLink: Binding<URL?>) {
            self.selection = selection
            self.activatedLink = activatedLink
        }

        public func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            guard
                let value = message.body as? [String: Any],
                let text = value["text"] as? String,
                let start = value["utf8Start"] as? Int,
                let length = value["utf8Length"] as? Int,
                !text.isEmpty
            else {
                selection.wrappedValue = nil
                return
            }
            let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
            selection.wrappedValue = ReaderSelectionContext(
                itemRevisionID: itemRevisionID,
                span: TextSpan(utf8Start: start, utf8Length: length, excerptHash: hash),
                selectedText: text
            )
        }

        public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                decisionHandler(.cancel)
                if let fragment = ReaderDocumentNavigation.fragment(for: url, relativeTo: baseURL) {
                    // Only app-owned code executes in the isolated Reader world.
                    Task { @MainActor in
                        _ = try? await webView.callAsyncJavaScript("if (!fragment) { window.scrollTo(0, 0); } else { document.getElementById(fragment)?.scrollIntoView({block: 'start'}); }", arguments: ["fragment": fragment], in: nil, contentWorld: .world(name: "CrosscurrentReaderSelection"))
                    }
                } else {
                    activatedLink.wrappedValue = url
                }
            } else {
                decisionHandler(.allow)
            }
        }
    }

    private static let selectionScript = #"""
    (() => {
      const byteCount = value => new TextEncoder().encode(value).length;
      const articleTextOffset = (targetNode, targetOffset) => {
        const article = document.querySelector('article');
        if (!article) return null;
        const walker = document.createTreeWalker(article, NodeFilter.SHOW_TEXT);
        let offset = 0;
        while (walker.nextNode()) {
          if (walker.currentNode === targetNode) {
            return offset + byteCount((targetNode.nodeValue || '').slice(0, targetOffset));
          }
          offset += byteCount(walker.currentNode.nodeValue || '');
        }
        return null;
      };
      let timer;
      document.addEventListener('selectionchange', () => {
        clearTimeout(timer);
        timer = setTimeout(() => {
          const selected = window.getSelection();
          if (!selected || selected.rangeCount === 0 || selected.isCollapsed) {
            webkit.messageHandlers.crosscurrentSelection.postMessage({});
            return;
          }
          const range = selected.getRangeAt(0);
          const text = selected.toString();
          const start = articleTextOffset(range.startContainer, range.startOffset);
          if (start == null || !text) return;
          webkit.messageHandlers.crosscurrentSelection.postMessage({text, utf8Start:start, utf8Length:byteCount(text)});
        }, 80);
      });
    })();
    """#
}

enum ReaderDocumentNavigation {
    static func fragment(for target: URL, relativeTo base: URL?) -> String? {
        guard let base, var destination = URLComponents(url: target, resolvingAgainstBaseURL: true),
              let fragment = destination.fragment,
              var origin = URLComponents(url: base, resolvingAgainstBaseURL: true) else { return nil }
        destination.fragment = nil
        origin.fragment = nil
        return destination.url == origin.url ? fragment : nil
    }
}

private final class ReaderEscapeWebView: WKWebView {
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 53 else {
            super.keyDown(with: event)
            return
        }
        onEscape?()
    }
}

public enum OriginalPageLoadState: Equatable, Sendable {
    case loading, loaded, failed
}

public struct PublicOriginalWebView: NSViewRepresentable {
    public var url: URL
    private var reloadRequest: Int
    private var onEscape: () -> Void
    private var onLoadStateChange: (OriginalPageLoadState) -> Void

    public init(url: URL, reloadRequest: Int = 0, onEscape: @escaping () -> Void = {}, onLoadStateChange: @escaping (OriginalPageLoadState) -> Void = { _ in }) {
        self.url = url
        self.reloadRequest = reloadRequest
        self.onEscape = onEscape
        self.onLoadStateChange = onLoadStateChange
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(url: url, reloadRequest: reloadRequest, onLoadStateChange: onLoadStateChange)
    }

    public func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = ReaderEscapeWebView(frame: .zero, configuration: configuration)
        view.onEscape = onEscape
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        (webView as? ReaderEscapeWebView)?.onEscape = onEscape
        context.coordinator.onLoadStateChange = onLoadStateChange
        if context.coordinator.url != url || context.coordinator.reloadRequest != reloadRequest {
            context.coordinator.url = url
            context.coordinator.reloadRequest = reloadRequest
            webView.load(URLRequest(url: url))
        }
    }

    public final class Coordinator: NSObject, WKNavigationDelegate {
        fileprivate var url: URL
        fileprivate var reloadRequest: Int
        fileprivate var onLoadStateChange: (OriginalPageLoadState) -> Void

        fileprivate init(url: URL, reloadRequest: Int, onLoadStateChange: @escaping (OriginalPageLoadState) -> Void) {
            self.url = url
            self.reloadRequest = reloadRequest
            self.onLoadStateChange = onLoadStateChange
        }

        public func webView(_: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
            onLoadStateChange(.loading)
        }

        public func webView(_: WKWebView, didFinish _: WKNavigation!) {
            onLoadStateChange(.loaded)
        }

        public func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
            reportFailure(error)
        }

        public func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
            reportFailure(error)
        }

        public func webViewWebContentProcessDidTerminate(_: WKWebView) {
            onLoadStateChange(.failed)
        }

        private func reportFailure(_ error: Error) {
            // A replacement navigation cancels the old request; it is still loading.
            let failure = error as NSError
            guard failure.domain != NSURLErrorDomain || failure.code != NSURLErrorCancelled else { return }
            onLoadStateChange(.failed)
        }
    }
}
