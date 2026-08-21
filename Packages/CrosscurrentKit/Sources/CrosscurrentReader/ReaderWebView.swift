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
        context.coordinator.renderTask?.cancel()
        context.coordinator.renderTask = Task {
            let renderedHTML = await ReaderHTMLPreparer.prepare(document.sanitizedHTML)
            guard !Task.isCancelled, context.coordinator.loadedIdentity == loadIdentity else { return }
            webView.loadHTMLString(Self.page(document: document, renderedHTML: renderedHTML), baseURL: document.baseURL)
        }
    }

    private static func page(document: ReaderDocument, renderedHTML: String) -> String {
        let escapedTitle = document.title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="referrer" content="no-referrer">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data: blob: app-asset:; style-src 'unsafe-inline'; font-src data: app-asset:; connect-src 'none'; frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'">
        <style>
        :root{color-scheme:light dark;--accent:#d5603f;--muted:color-mix(in srgb,CanvasText 62%,Canvas);--rule:color-mix(in srgb,CanvasText 18%,Canvas);--code:color-mix(in srgb,CanvasText 7%,Canvas)}
        *{box-sizing:border-box}body{font:18px/1.72 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;padding:36px clamp(24px,8vw,72px) 72px;max-width:900px;margin:auto;color:CanvasText;background:Canvas;overflow-wrap:break-word}article{min-width:0}h1,h2,h3,h4,h5,h6{line-height:1.22;letter-spacing:-.018em;margin:1.8em 0 .65em;text-wrap:balance}h1{font-size:clamp(2rem,5vw,2.65rem);line-height:1.1;margin-top:.2em}h2{font-size:1.55em}h3{font-size:1.25em}p,ul,ol,blockquote,pre,table,figure{margin-top:1.05em;margin-bottom:1.05em}ul,ol{padding-left:1.45em}li>ul,li>ol{margin:.35em 0}a{color:var(--accent);text-decoration-thickness:.08em;text-underline-offset:.15em}hr{border:0;border-top:1px solid var(--rule);margin:2.4em 0}blockquote{border-left:3px solid var(--accent);margin-left:0;padding:.05em 0 .05em 1.1em;color:var(--muted)}code{font:0.88em/1.55 ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--code);padding:.12em .32em;border-radius:4px}pre{overflow:auto;white-space:pre;padding:1em 1.1em;background:var(--code);border:1px solid var(--rule);border-radius:9px;tab-size:4;-webkit-overflow-scrolling:touch}pre code{font-size:.86em;background:none;padding:0;border-radius:0}figure{margin-left:0;margin-right:0;text-align:center}img,svg{display:block;max-width:100%;height:auto;margin-left:auto;margin-right:auto}img{border-radius:7px}figcaption{max-width:68ch;margin:.65em auto 0;color:var(--muted);font-size:.88em;line-height:1.45}table{display:block;width:max-content;max-width:100%;overflow-x:auto;border-collapse:collapse;border-spacing:0;-webkit-overflow-scrolling:touch}th,td{min-width:8em;padding:.62em .75em;border:1px solid var(--rule);text-align:left;vertical-align:top}th{font-weight:650;background:var(--code)}math{font-size:1.04em}math[display="block"]{display:block;max-width:100%;overflow-x:auto;overflow-y:hidden;margin:1.25em 0;padding:.2em 0;text-align:center;-webkit-overflow-scrolling:touch}@media(max-width:560px){body{font-size:17px;padding:24px 20px 56px}th,td{min-width:7em}}
        </style>
        </head><body><article><h1>\(escapedTitle)</h1>\(renderedHTML)</article></body></html>
        """
    }

    public final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        fileprivate var selection: Binding<ReaderSelectionContext?>
        fileprivate var activatedLink: Binding<URL?>
        fileprivate var itemRevisionID = ItemRevisionID()
        fileprivate var loadedIdentity: String?
        fileprivate var renderTask: Task<Void, Never>?

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
