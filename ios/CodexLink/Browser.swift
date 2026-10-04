import SwiftUI
import WebKit

// WebKit invokes its UI/navigation/download delegates on the main thread.
// Keep ObjC delegate conformance nonisolated for Xcode 15 / Swift 5 SDKs.
final class BrowserSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let webView: WKWebView
    private var origin: URL?
    private var pin = ""
    private var pageFailed = false
    var needsReload: Bool { pageFailed || webView.url == nil }
    @Published var downloadedFile: URL?
    var onFailure: ((String) -> Void)?
    private var downloads: [ObjectIdentifier: URL] = [:]

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.contentInsetAdjustmentBehavior = .never
    }

    @MainActor func connect(base: URL, fingerprint: String, cookie: LinkCookie) async throws {
        guard cookie.name == "codex_mobile_session", cookie.value.count >= 32,
              let host = base.host else { throw LinkError.message("网页登录凭据无效") }
        // Parsing Set-Cookie preserves host-only / HttpOnly / SameSite semantics.
        let header = "\(cookie.name)=\(cookie.value); Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=\(min(cookie.maxAge, 43200))"
        guard let parsed = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": header], for: base).first,
              bareHost(parsed.domain) == bareHost(host) else { throw LinkError.message("无法创建安全会话") }
        await webView.configuration.websiteDataStore.httpCookieStore.setCookie(parsed)
        let changed = origin != base
        origin = base
        pin = fingerprint
        if changed || needsReload {
            pageFailed = false
            webView.stopLoading()
            webView.load(URLRequest(url: base))
        }
    }

    func clear() {
        webView.stopLoading()
        origin = nil
        pin = ""
        pageFailed = false
        webView.loadHTMLString("", baseURL: nil)
        let store = webView.configuration.websiteDataStore
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }

    func reload() { if origin != nil { webView.reload() } }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let origin, let credential = pinnedCredential(challenge, endpoint: origin, pin: pin) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, credential)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.absoluteString == "about:blank" { decisionHandler(.allow); return }
        guard let origin, sameOrigin(url, origin) else {
            if navigationAction.navigationType == .linkActivated && url.scheme == "https" {
                UIApplication.shared.open(url) // User-clicked external links only; never forward cookies.
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let response = navigationResponse.response as? HTTPURLResponse
        let attachment = response?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") == true
        decisionHandler(attachment || !navigationResponse.canShowMIMEType ? .download : .allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let origin, let url = navigationAction.request.url, sameOrigin(url, origin) {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled {
            pageFailed = true
            onFailure?(error.localizedDescription)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { pageFailed = false }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { reload() }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard let origin, let url = response.url, sameOrigin(url, origin) else { completionHandler(nil); return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CodexLink-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = URL(fileURLWithPath: suggestedFilename).lastPathComponent
            let destination = directory.appendingPathComponent(name.isEmpty || name == "." || name == ".." ? "download" : name)
            downloads[ObjectIdentifier(download)] = destination
            completionHandler(destination)
        } catch { completionHandler(nil) }
    }

    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void) {
        // Download credentials are also restricted to the paired origin.
        decisionHandler(origin.flatMap { base in request.url.map { sameOrigin($0, base) } } == true ? .allow : .cancel)
    }

    func download(_ download: WKDownload, didReceive challenge: URLAuthenticationChallenge,
                  completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let origin, let credential = pinnedCredential(challenge, endpoint: origin, pin: pin) else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, credential)
    }

    func downloadDidFinish(_ download: WKDownload) { downloadedFile = downloads.removeValue(forKey: ObjectIdentifier(download)) }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let file = downloads.removeValue(forKey: ObjectIdentifier(download)) {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        onFailure?("下载失败：" + error.localizedDescription)
    }
}

struct BrowserView: UIViewRepresentable {
    let browser: BrowserSession
    func makeUIView(context: Context) -> WKWebView { browser.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct ShareView: UIViewControllerRepresentable {
    let file: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [file], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
