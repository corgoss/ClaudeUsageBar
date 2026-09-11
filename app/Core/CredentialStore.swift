import Foundation

public struct StoredCookie: Codable, Equatable {
    public let name: String
    public let value: String
    public let domain: String
    public let path: String
    public let expiresAt: Date?
    public let isSecure: Bool

    public init(name: String, value: String, domain: String = ".claude.ai",
                path: String = "/", expiresAt: Date? = nil, isSecure: Bool = true) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expiresAt = expiresAt
        self.isSecure = isSecure
    }

    public init?(_ cookie: HTTPCookie) {
        guard !cookie.name.isEmpty else { return nil }
        self.init(name: cookie.name, value: cookie.value, domain: cookie.domain,
                  path: cookie.path.isEmpty ? "/" : cookie.path,
                  expiresAt: cookie.expiresDate, isSecure: cookie.isSecure)
    }

    public var httpCookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: domain, .path: path, .name: name, .value: value,
        ]
        if let expiresAt { properties[.expires] = expiresAt }
        if isSecure { properties[.secure] = true }
        return HTTPCookie(properties: properties)
    }
}

public enum CookieDiff {
    public static func changed(from old: [StoredCookie], to new: [StoredCookie]) -> Bool {
        func key(_ cookies: [StoredCookie]) -> [String: String] {
            Dictionary(cookies.map {
                ($0.name, "\($0.value)|\($0.expiresAt?.timeIntervalSince1970 ?? -1)")
            }, uniquingKeysWith: { first, _ in first })
        }
        return key(old) != key(new)
    }
}

public protocol CredentialStore: AnyObject {
    func save(_ cookies: [StoredCookie], for accountId: String) throws
    func load(for accountId: String) throws -> [StoredCookie]
    func delete(for accountId: String) throws
}

public final class InMemoryCredentialStore: CredentialStore {
    private var storage: [String: [StoredCookie]] = [:]

    public init() {}

    public func save(_ cookies: [StoredCookie], for accountId: String) throws {
        storage[accountId] = cookies
    }

    public func load(for accountId: String) throws -> [StoredCookie] {
        storage[accountId] ?? []
    }

    public func delete(for accountId: String) throws {
        storage.removeValue(forKey: accountId)
    }
}