import AppKit
import WebKit

final class AccountLoginWindow: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    enum Mode {
        case newAccount
        case reauth(accountId: String, expectedEmail: String?)
    }

    private var window: NSWindow?
    private var webView: WKWebView!
    private var dataStore: WKWebsiteDataStore!
    private var popupWindows: [ObjectIdentifier: NSWindow] = [:]
    private var pollTimer: Timer?
    private var verificationSession: ClaudeSession?
    private var didComplete = false
    private var isClosing = false

    private let mode: Mode
    private let onSuccess: (String, String?, [HTTPCookie]) throws -> Void
    private let onIdentityMismatch: (String, String) -> Void

    private static var live: AccountLoginWindow?

    static func present(mode: Mode,
                        onSuccess: @escaping (String, String?, [HTTPCookie]) throws -> Void,
                        onIdentityMismatch: @escaping (String, String) -> Void = { _, _ in }) {
        live?.close()
        live = AccountLoginWindow(mode: mode, onSuccess: onSuccess,
                                  onIdentityMismatch: onIdentityMismatch)
        live?.show()
    }

    private init(mode: Mode,
                 onSuccess: @escaping (String, String?, [HTTPCookie]) throws -> Void,
                 onIdentityMismatch: @escaping (String, String) -> Void) {
        self.mode = mode
        self.onSuccess = onSuccess
        self.onIdentityMismatch = onIdentityMismatch
        super.init()
    }

    private func show() {
        dataStore = WKWebsiteDataStore.nonPersistent()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 760),
                            configuration: configuration)
        webView.customUserAgent = ClaudeSession.userAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self

        let window = NSWindow(contentRect: webView.frame,
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Sign in to Claude"
        window.contentView = webView
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        webView.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
        startPollingForSession()
    }

    private func startPollingForSession() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self, !self.didComplete else {
                timer.invalidate()
                return
            }
            self.dataStore.httpCookieStore.getAllCookies { cookies in
                let claude = cookies.filter { $0.domain.contains("claude.ai") }
                guard claude.contains(where: { $0.name == "sessionKey" }) else { return }
                self.didComplete = true
                timer.invalidate()
                self.verify(cookies: CookiePolicy.filter(claude))
            }
        }
    }

    private func verify(cookies: [HTTPCookie]) {
        let session = ClaudeSession(accountId: "login-verify", cookies: cookies)
        verificationSession = session
        session.get(path: "/api/bootstrap") { [weak self] result in
            guard let self else { return }
            self.verificationSession = nil
            guard case .success(let data) = result,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let account = json["account"] as? [String: Any] else {
                self.didComplete = false
                self.startPollingForSession()
                return
            }

            let email = (account["email_address"] as? String)
                ?? (account["full_name"] as? String) ?? "Claude account"
            let orgId = cookies.first { $0.name == "lastActiveOrg" }?.value

            if case .reauth(_, let expected) = self.mode,
               let expected, !expected.isEmpty, expected != email {
                self.close()
                self.onIdentityMismatch(email, expected)
                return
            }

            let persistence = LoginCompletion.persistThenClose(
                persist: { try self.onSuccess(email, orgId, cookies) },
                close: { self.close() }
            )
            if case .failure(let error) = persistence {
                self.showPersistenceFailure(error)
            }
        }
    }

    private func showPersistenceFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could Not Save Sign-In"
        alert.informativeText = "macOS did not grant ClaudeUsageBar access to the Keychain. Choose Try Again, then approve access when prompted.\n\n\(error)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Try Again")

        guard let window else {
            didComplete = false
            startPollingForSession()
            return
        }
        alert.beginSheetModal(for: window) { [weak self] _ in
            guard let self, !self.isClosing else { return }
            self.didComplete = false
            self.startPollingForSession()
        }
    }

    private func close(closeWindow: Bool = true) {
        guard !isClosing else { return }
        isClosing = true
        didComplete = true
        pollTimer?.invalidate()
        pollTimer = nil
        verificationSession = nil
        popupWindows.values.forEach { $0.close() }
        popupWindows.removeAll()
        webView?.stopLoading()
        let mainWindow = window
        window = nil
        if closeWindow {
            mainWindow?.delegate = nil
            mainWindow?.close()
        }
        webView = nil
        dataStore = nil
        NSApp.setActivationPolicy(.accessory)
        AccountLoginWindow.live = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard let closedWindow = notification.object as? NSWindow,
              closedWindow === window else { return }
        close(closeWindow: false)
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640),
                              configuration: configuration)
        popup.customUserAgent = ClaudeSession.userAgent
        popup.navigationDelegate = self
        popup.uiDelegate = self

        let window = NSWindow(contentRect: popup.frame,
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Sign in"
        window.contentView = popup
        window.center()
        window.makeKeyAndOrderFront(nil)

        popupWindows[ObjectIdentifier(popup)] = window
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        let key = ObjectIdentifier(webView)
        popupWindows[key]?.close()
        popupWindows[key] = nil
    }
}