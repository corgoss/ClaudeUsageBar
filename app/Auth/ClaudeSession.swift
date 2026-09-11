import Foundation

#if canImport(ClaudeUsageBarCore)
import ClaudeUsageBarCore
#endif

public enum SessionError: Error {
	case unauthorized
	case http(Int)
	case transport(Error)
	case invalidResponse
}

public final class ClaudeSession {
	public static let userAgent =
		"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
		+ "(KHTML, like Gecko) Version/17.4.1 Safari/605.1.15"

	private static let baseURL = URL(string: "https://claude.ai")!

	public let accountId: String
	private let configuration: URLSessionConfiguration
	private let session: URLSession
	private var lastPersisted: [StoredCookie]

	public var onCookiesChanged: (([HTTPCookie]) -> Void)?

	public init(accountId: String, cookies: [HTTPCookie]) {
		self.accountId = accountId

		let configuration = URLSessionConfiguration.ephemeral
		configuration.httpCookieAcceptPolicy = .always
		configuration.httpShouldSetCookies = true
		configuration.httpAdditionalHeaders = [
			"User-Agent": ClaudeSession.userAgent,
			"Accept": "*/*",
			"Origin": "https://claude.ai",
			"Referer": "https://claude.ai/",
		]

		for cookie in CookiePolicy.filter(cookies) {
			configuration.httpCookieStorage?.setCookie(cookie)
		}

		self.configuration = configuration
		self.session = URLSession(configuration: configuration)
		self.lastPersisted = CookiePolicy.filter(cookies).compactMap(StoredCookie.init)
	}

	public var currentCookies: [HTTPCookie] {
		CookiePolicy.filter(configuration.httpCookieStorage?.cookies(for: Self.baseURL) ?? [])
	}

	public var sessionKeyExpiry: Date? {
		CookiePolicy.sessionExpiry(in: currentCookies)
	}

	public func makeRequest(path: String) -> URLRequest {
		var request = URLRequest(url: Self.baseURL.appendingPathComponent(path))
		request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
		return request
	}

	public func get(path: String, completion: @escaping (Result<Data, SessionError>) -> Void) {
		session.dataTask(with: makeRequest(path: path)) { [weak self] data, response, error in
			guard let self else { return }

			DispatchQueue.main.async {
				self.captureCookieRotation()

				if let error {
					completion(.failure(.transport(error)))
					return
				}
				guard let response = response as? HTTPURLResponse else {
					completion(.failure(.invalidResponse))
					return
				}
				switch response.statusCode {
				case 200:
					guard let data else {
						completion(.failure(.invalidResponse))
						return
					}
					completion(.success(data))
				case 401, 403:
					completion(.failure(.unauthorized))
				default:
					completion(.failure(.http(response.statusCode)))
				}
			}
		}.resume()
	}

	private func captureCookieRotation() {
		let current = currentCookies.compactMap(StoredCookie.init)
		guard CookieDiff.changed(from: lastPersisted, to: current) else { return }
		NSLog("[\(accountId)] server rotated cookies: \(current.map(\.name).sorted())")
		lastPersisted = current
		onCookiesChanged?(currentCookies)
	}
}