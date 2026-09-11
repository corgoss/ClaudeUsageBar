import Foundation

public struct Account: Identifiable, Codable, Equatable {
    public let id: String
    public var name: String
    public var email: String?
    public var orgId: String?
    public var sessionPercentage: Int?
    public var expiresAt: Date?
    public var lastSuccessfulFetch: Date?
    public var lastRenewalAttempt: Date?
    public var consecutiveAuthFailures: Int
    public var lastFetchFailedNonAuth: Bool

    public init(id: String = UUID().uuidString,
                name: String,
                email: String? = nil,
                orgId: String? = nil,
                sessionPercentage: Int? = nil,
                expiresAt: Date? = nil,
                lastSuccessfulFetch: Date? = nil,
                lastRenewalAttempt: Date? = nil,
                consecutiveAuthFailures: Int = 0,
                lastFetchFailedNonAuth: Bool = false) {
        self.id = id
        self.name = name
        self.email = email
        self.orgId = orgId
        self.sessionPercentage = sessionPercentage
        self.expiresAt = expiresAt
        self.lastSuccessfulFetch = lastSuccessfulFetch
        self.lastRenewalAttempt = lastRenewalAttempt
        self.consecutiveAuthFailures = consecutiveAuthFailures
        self.lastFetchFailedNonAuth = lastFetchFailedNonAuth
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        orgId = try container.decodeIfPresent(String.self, forKey: .orgId)
        sessionPercentage = try container.decodeIfPresent(Int.self, forKey: .sessionPercentage)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        lastSuccessfulFetch = try container.decodeIfPresent(Date.self, forKey: .lastSuccessfulFetch)
        lastRenewalAttempt = try container.decodeIfPresent(Date.self, forKey: .lastRenewalAttempt)
        consecutiveAuthFailures =
            try container.decodeIfPresent(Int.self, forKey: .consecutiveAuthFailures) ?? 0
        lastFetchFailedNonAuth =
            try container.decodeIfPresent(Bool.self, forKey: .lastFetchFailedNonAuth) ?? false
    }
}