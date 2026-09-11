import Foundation

public struct LegacyAccount: Codable, Equatable {
    public let id: String
    public var name: String
    public var cookie: String
    public var sessionPercentage: Int?

    public init(id: String, name: String, cookie: String, sessionPercentage: Int?) {
        self.id = id
        self.name = name
        self.cookie = cookie
        self.sessionPercentage = sessionPercentage
    }
}

public struct MigrationResult: Equatable {
    public let accounts: [Account]
    public let credentials: [String: [StoredCookie]]
}

public enum Migration {
    public static func migrate(legacy: [LegacyAccount]) -> MigrationResult {
        var accounts: [Account] = []
        var credentials: [String: [StoredCookie]] = [:]

        for record in legacy {
            let cookies = CookiePolicy.parse(pasted: record.cookie)
            credentials[record.id] = cookies.compactMap(StoredCookie.init)

            accounts.append(Account(
                id: record.id,
                name: record.name,
                orgId: cookies.first { $0.name == "lastActiveOrg" }?.value,
                sessionPercentage: record.sessionPercentage,
                expiresAt: nil
            ))
        }

        return MigrationResult(accounts: accounts, credentials: credentials)
    }
}