import AppKit
import WebKit

/// Markdown and HTML: rendered with WebKit, both in the viewer and for card thumbnails.
enum WebDoc {
    static let markdownExts: Set<String> = ["md", "markdown", "mdown", "mkd"]
    static let htmlExts: Set<String> = ["html", "htm", "xhtml"]

    static func isWeb(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return markdownExts.contains(ext) || htmlExts.contains(ext)
    }

    static func isMarkdown(_ url: URL) -> Bool { markdownExts.contains(url.pathExtension.lowercased()) }

    private static let markedJS: String? = {
        guard let url = Bundle.main.url(forResource: "marked", withExtension: "js", subdirectory: "web") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    /// The page to load: HTML as-is; Markdown rendered into a sibling hidden file so
    /// relative images (copied next to it by the CLI) still resolve.
    static func pageURL(for url: URL) -> URL {
        guard isMarkdown(url) else { return url }
        let out = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).peek.html")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) ?? ""
        try? renderMarkdown(text, title: url.deletingPathExtension().lastPathComponent).write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    static func renderMarkdown(_ text: String, title: String) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: [text]))
            .flatMap { String(data: $0, encoding: .utf8) }?
            .replacingOccurrences(of: "</", with: "<\\/") ?? "[\"\"]"
        let body: String
        if let js = markedJS {
            body = """
            <article id="doc" class="md"></article>
            <script>\(js.replacingOccurrences(of: "</script", with: "<\\/script"))</script>
            <script>
            const src = \(json)[0];
            document.getElementById('doc').innerHTML = marked.parse(src, { gfm: true });
            document.querySelectorAll('a[href^="http"]').forEach(a => a.setAttribute('target', '_blank'));
            </script>
            """
        } else {
            body = "<pre class=\"md\" id=\"doc\"></pre><script>document.getElementById('doc').textContent = \(json)[0];</script>"
        }
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title.replacingOccurrences(of: "<", with: "&lt;"))</title>
        <style>\(css)</style></head>
        <body>\(body)</body></html>
        """
    }

    private static let css = """
    :root { color-scheme: light dark; --fg:#1f2328; --muted:#59636e; --line:#d1d9e0; --soft:#f6f8fa; --link:#0969da; --bg:#ffffff; }
    @media (prefers-color-scheme: dark) { :root { --fg:#e6edf3; --muted:#9198a1; --line:#3d444d; --soft:#151b23; --link:#4493f8; --bg:#121212; } }
    html { background: var(--bg); }
    body { margin: 0; padding: 36px 44px 64px; font: 15px/1.65 -apple-system, "PingFang SC", "Helvetica Neue", sans-serif; color: var(--fg); }
    .md { max-width: 820px; margin: 0 auto; word-wrap: break-word; }
    h1, h2, h3, h4 { line-height: 1.3; margin: 1.6em 0 .6em; font-weight: 650; }
    h1 { font-size: 1.9em; margin-top: .2em; padding-bottom: .3em; border-bottom: 1px solid var(--line); }
    h2 { font-size: 1.45em; padding-bottom: .25em; border-bottom: 1px solid var(--line); }
    h3 { font-size: 1.2em; }
    p, ul, ol, table, pre, blockquote { margin: 0 0 1em; }
    a { color: var(--link); text-decoration: none; } a:hover { text-decoration: underline; }
    code { font: .88em/1.5 "SF Mono", Menlo, monospace; background: var(--soft); border-radius: 5px; padding: .15em .4em; }
    pre { background: var(--soft); border: 1px solid var(--line); border-radius: 10px; padding: 14px 16px; overflow: auto; }
    pre code { background: none; padding: 0; font-size: .85em; }
    blockquote { margin-left: 0; padding: 0 1em; color: var(--muted); border-left: 3px solid var(--line); }
    table { border-collapse: collapse; display: block; overflow: auto; }
    th, td { border: 1px solid var(--line); padding: 6px 13px; }
    th { background: var(--soft); font-weight: 600; }
    tr:nth-child(2n) td { background: color-mix(in srgb, var(--soft) 55%, transparent); }
    img { max-width: 100%; border-radius: 6px; }
    hr { border: 0; border-top: 1px solid var(--line); margin: 2em 0; }
    li + li { margin-top: .25em; }
    input[type=checkbox] { margin-right: .4em; }
    """
}

/// WKWebView for the viewer: file access limited to the card's own folder,
/// links to the web open in your browser.
final class WebDocView: WKWebView, WKNavigationDelegate, WKUIDelegate {
    /// Unknown while loading: preserve document scrolling until its layout is known.
    private(set) var hasHorizontalOverflow: Bool?

    init(url: URL) {
        let cfg = WKWebViewConfiguration()
        cfg.preferences.isElementFullscreenEnabled = true
        super.init(frame: .zero, configuration: cfg)
        navigationDelegate = self
        uiDelegate = self
        allowsMagnification = true
        allowsBackForwardNavigationGestures = true
        underPageBackgroundColor = NSColor(white: 0.075, alpha: 1)
        let page = WebDoc.pageURL(for: url)
        loadFileURL(page, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshHorizontalOverflow()
    }

    private func refreshHorizontalOverflow() {
        guard url != nil, !isLoading else { return }
        evaluateJavaScript("""
        (() => {
            const root = document.scrollingElement;
            if (root && root.scrollWidth > root.clientWidth + 1) return true;
            return [...document.querySelectorAll('body, body *')].some(el =>
                /auto|scroll/.test(getComputedStyle(el).overflowX) && el.scrollWidth > el.clientWidth + 1);
        })()
        """) { [weak self] result, _ in
            self?.hasHorizontalOverflow = result as? Bool
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshHorizontalOverflow()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        hasHorizontalOverflow = nil
    }

    func zoom(_ action: ZoomImageView.Action) {
        switch action {
        case .fit: pageZoom = 1
        case .actual: pageZoom = 1
        case .zoomIn: pageZoom = min(3, pageZoom * 1.15)
        case .zoomOut: pageZoom = max(0.4, pageZoom / 1.15)
        }
        refreshHorizontalOverflow()
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url, let scheme = url.scheme?.lowercased(),
           ["http", "https", "mailto"].contains(scheme),
           action.navigationType == .linkActivated || action.targetFrame == nil {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    // target=_blank links ask for a new window: send those to the browser too.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { NSWorkspace.shared.open(url) }
        return nil
    }
}

/// Renders a page offscreen and takes a picture of its first screenful.
final class WebSnapshot: NSObject, WKNavigationDelegate {
    private static var live = Set<WebSnapshot>()
    private let window: NSWindow
    private let web: WKWebView
    private var done: ((NSImage?) -> Void)?
    private var finished = false

    static func capture(_ url: URL, done: @escaping (NSImage?) -> Void) {
        let s = WebSnapshot(url: url, done: done)
        live.insert(s)
    }

    private init(url: URL, done: @escaping (NSImage?) -> Void) {
        let size = WebDoc.isMarkdown(url) ? NSSize(width: 820, height: 900) : NSSize(width: 1180, height: 760)
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        web = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: WKWebViewConfiguration())
        self.done = done
        super.init()
        window.contentView = web
        web.navigationDelegate = self
        web.loadFileURL(WebDoc.pageURL(for: url), allowingReadAccessTo: url.deletingLastPathComponent())
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.shoot() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Give fonts, images and scripts a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.shoot() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(nil) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(nil) }

    private func shoot() {
        guard !finished else { return }
        finished = true
        let cfg = WKSnapshotConfiguration()
        cfg.rect = web.bounds
        cfg.snapshotWidth = NSNumber(value: Double(min(web.bounds.width, 720)))
        web.takeSnapshot(with: cfg) { [weak self] img, _ in self?.finish(img) }
    }

    private func finish(_ img: NSImage?) {
        finished = true
        let cb = done
        done = nil
        cb?(img)
        web.navigationDelegate = nil
        window.close()
        WebSnapshot.live.remove(self)
    }
}
