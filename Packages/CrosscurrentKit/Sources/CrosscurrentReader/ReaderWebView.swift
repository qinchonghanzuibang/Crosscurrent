import CryptoKit
import CrosscurrentDomain
import SwiftUI
import WebKit

public struct ReaderDocument: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var byline: String?
    public var sanitizedHTML: String
    public var baseURL: URL?
    public var itemRevisionID: ItemRevisionID

    public init(id: String, title: String, byline: String? = nil, sanitizedHTML: String, baseURL: URL? = nil, itemRevisionID: ItemRevisionID = ItemRevisionID()) {
        self.id = id
        self.title = title
        self.byline = byline
        self.sanitizedHTML = sanitizedHTML
        self.baseURL = baseURL
        self.itemRevisionID = itemRevisionID
    }
}

public struct ReaderWebView: NSViewRepresentable {
    public var document: ReaderDocument
    @Binding private var selection: ReaderSelectionContext?
    @Binding private var activatedLink: URL?

    public init(
        document: ReaderDocument,
        selection: Binding<ReaderSelectionContext?> = .constant(nil),
        activatedLink: Binding<URL?> = .constant(nil)
    ) {
        self.document = document
        _selection = selection
        _activatedLink = activatedLink
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
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.activatedLink = $activatedLink
        context.coordinator.itemRevisionID = document.itemRevisionID
        let loadIdentity = document.id + ":" + String(document.sanitizedHTML.hashValue)
        guard context.coordinator.loadedIdentity != loadIdentity else { return }
        context.coordinator.loadedIdentity = loadIdentity
        let escapedTitle = document.title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let page = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: blob: app-asset:; style-src 'unsafe-inline'; font-src data: app-asset:; connect-src 'none'; frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'">
        <style>:root{color-scheme:light dark}body{font:18px/1.72 -apple-system;padding:36px 8%;max-width:760px;margin:auto;color:CanvasText;background:Canvas}h1{font-size:2.15em;line-height:1.12;letter-spacing:-.025em}img{max-width:100%;height:auto;border-radius:10px}a{color:#d5603f}blockquote{border-left:3px solid #d5603f;margin-left:0;padding-left:1.1em;color:GrayText}pre{overflow:auto;padding:1em;background:color-mix(in srgb,CanvasText 7%,Canvas);border-radius:8px}</style>
        </head><body><article><h1>\(escapedTitle)</h1>\(document.sanitizedHTML)</article></body></html>
        """
        webView.loadHTMLString(page, baseURL: document.baseURL)
    }

    public final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        fileprivate var selection: Binding<ReaderSelectionContext?>
        fileprivate var activatedLink: Binding<URL?>
        fileprivate var itemRevisionID = ItemRevisionID()
        fileprivate var loadedIdentity: String?

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

        public func webView(_: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                activatedLink.wrappedValue = url
                decisionHandler(.cancel)
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

public struct PublicOriginalWebView: NSViewRepresentable {
    public var url: URL
    public init(url: URL) { self.url = url }

    public func makeNSView(context _: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.load(URLRequest(url: url))
        return view
    }

    public func updateNSView(_: WKWebView, context _: Context) {}
}
