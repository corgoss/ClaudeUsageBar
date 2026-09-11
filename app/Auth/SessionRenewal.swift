import AppKit
import WebKit

#if canImport(ClaudeUsageBarCore)
import ClaudeUsageBarCore
#endif

enum SessionRenewal {
    private static var inFlight: [String: RenewalTask] = [:]

    static func attempt(accountId: String,
                        cookies: [HTTPCookie],
                        completion: @escaping ([HTTPCookie]?) -> Void) {
        let allowedCookies = CookiePolicy.filter(cookies)
        guard inFlight[accountId] == nil, !allowedCookies.isEmpty else {
            completion(nil)
            return
        }
        let task = RenewalTask(accountId: accountId, cookies: allowedCookies) { renewed in
            inFlight[accountId] = nil
            completion(renewed)
        }
        inFlight[accountId] = task
        task.start()
    }

    private final class RenewalTask {
        private let accountId: String
        private let original: [HTTPCookie]
        private let completion: ([HTTPCookie]?) -> Void
        private var webView: WKWebView?
        private var dataStore: WKWebsiteDataStore?

        init(accountId: String, cookies: [HTTPCookie],
             completion: @escaping ([HTTPCookie]?) -> Void) {
            self.accountId = accountId
            self.original = cookies
            self.completion = completion
        }

        func start() {
            let dataStore = WKWebsiteDataStore.nonPersistent()
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = dataStore

            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1, height: 1),
                                    configuration: configuration)
            webView.customUserAgent = ClaudeSession.userAgent
            self.webView = webView
            self.dataStore = dataStore

            let group = DispatchGroup()
            for cookie in original {
                group.enter()
                dataStore.httpCookieStore.setCookie(cookie) { group.leave() }
            }

            group.notify(queue: .main) {
                webView.load(URLRequest(url: URL(string: "https://claude.ai/")!))
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) { self.harvest() }
            }
        }

        private func harvest() {
            guard let dataStore else {
                finish(nil)
                return
            }
            dataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self else { return }
                let harvested = CookiePolicy.filter(cookies.filter { $0.domain.contains("claude.ai") })

                let oldKey = self.original.first { $0.name == "sessionKey" }
                let newKey = harvested.first { $0.name == "sessionKey" }
                guard let newKey else {
                    self.finish(nil)
                    return
                }

                let valueChanged = newKey.value != oldKey?.value
                let expiryExtended = (newKey.expiresDate ?? .distantPast)
                    > (oldKey?.expiresDate ?? .distantPast)

                if valueChanged || expiryExtended {
                    NSLog("[\(self.accountId)] silent renewal extended the session")
                    self.finish(harvested)
                } else {
                    self.finish(nil)
                }
            }
        }

        private func finish(_ result: [HTTPCookie]?) {
            webView?.stopLoading()
            webView = nil
            dataStore = nil
            DispatchQueue.main.async { self.completion(result) }
        }
    }
}