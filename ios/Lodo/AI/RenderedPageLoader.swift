import Foundation
import WebKit

/// 用一个不上屏的 WKWebView 把网页真正渲染一遍(跑页面自己的 JavaScript),
/// 再取渲染后的 DOM。给新闻全文抓取兜底:有些站正文是前端渲染的,直接抓 HTML
/// 只有一个空壳。
///
/// 只读页面、不留痕:用非持久化的 `WKWebsiteDataStore`(不写 cookie/缓存),
/// 不执行任何我们自己的脚本以外的交互,超时就放弃。
@MainActor
final class RenderedPageLoader: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<String?, Never>?
    private var timeoutTask: Task<Void, Never>?

    /// 渲染并返回 `document.documentElement.outerHTML`;失败/超时返回 nil。
    static func html(for url: URL, timeout: TimeInterval = 20) async -> String? {
        let loader = RenderedPageLoader()
        return await loader.load(url, timeout: timeout)
    }

    private func load(_ url: URL, timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844),
                                    configuration: configuration)
            webView.navigationDelegate = self
            self.webView = webView
            webView.load(URLRequest(url: url, timeoutInterval: timeout))
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.finish(nil)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            // 前端渲染的页面 didFinish 之后还要一会儿才把正文填进去。
            try? await Task.sleep(for: .seconds(1.5))
            let html = try? await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String
            self.finish(html)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }

    private func finish(_ html: String?) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        continuation.resume(returning: html)
    }
}
