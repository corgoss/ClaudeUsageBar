import Foundation

#if canImport(ClaudeUsageBarCore)
import ClaudeUsageBarCore
#endif

public final class AccountStore {
    private let accountsKey = "accounts_v3"
    private let activeKey = "active_account_id"
    private let migrationKey = "migrated_keychain_v1"
    private let legacyAccountsKey = "accounts_v2"
    private let legacyCookieKey = "claude_session_cookie"

    private let credentials: CredentialStore
    private let defaults: UserDefaults

    public private(set) var accounts: [Account] = []
    public private(set) var activeAccountId: String?

    /// Cookies already read from the credential store this session. Each miss is a
    /// keychain hit, and on an ad-hoc-signed build every keychain hit is a password
    /// prompt, so the refresh timer must never re-read what it already has.
    private var cookieCache: [String: [StoredCookie]] = [:]

    public init(credentials: CredentialStore = KeychainStore(),
                defaults: UserDefaults = .standard) {
        self.credentials = credentials
        self.defaults = defaults
        migrateIfNeeded()
        load()
    }

    private func load() {
        if let data = defaults.data(forKey: accountsKey),
           let decoded = try? JSONDecoder().decode([Account].self, from: data) {
            accounts = decoded
        }
        activeAccountId = defaults.string(forKey: activeKey)
        if activeAccountId == nil || !accounts.contains(where: { $0.id == activeAccountId }) {
            activeAccountId = accounts.first?.id
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(accounts) {
            defaults.set(data, forKey: accountsKey)
        }
        defaults.set(activeAccountId, forKey: activeKey)
    }

    private func migrateIfNeeded() {
        guard !defaults.bool(forKey: migrationKey) else { return }

        var legacy: [LegacyAccount] = []
        if let data = defaults.data(forKey: legacyAccountsKey),
           let decoded = try? JSONDecoder().decode([LegacyAccount].self, from: data) {
            legacy = decoded
        } else if let solitary = defaults.string(forKey: legacyCookieKey), !solitary.isEmpty {
            legacy = [LegacyAccount(id: UUID().uuidString, name: "Account 1",
                                    cookie: solitary, sessionPercentage: nil)]
        }

        guard !legacy.isEmpty else {
            defaults.set(true, forKey: migrationKey)
            return
        }

        let result = Migration.migrate(legacy: legacy)
        for (accountId, cookies) in result.credentials where !cookies.isEmpty {
            do {
                try credentials.save(cookies, for: accountId)
                cookieCache[accountId] = cookies
            } catch {
                NSLog("could not migrate credentials for \(accountId): \(error)")
                return
            }
        }
        if let data = try? JSONEncoder().encode(result.accounts) {
            defaults.set(data, forKey: accountsKey)
        }

        defaults.removeObject(forKey: legacyAccountsKey)
        defaults.removeObject(forKey: legacyCookieKey)
        defaults.set(true, forKey: migrationKey)
        NSLog("migrated \(result.accounts.count) account(s) to the keychain")
    }

    public func cookies(for accountId: String) -> [HTTPCookie] {
        storedCookies(for: accountId)
            .filter { CookiePolicy.allowlist.contains($0.name) }
            .compactMap(\.httpCookie)
    }

    private func storedCookies(for accountId: String) -> [StoredCookie] {
        if let cached = cookieCache[accountId] { return cached }
        // A throwing load means the keychain was unavailable or the prompt was
        // dismissed; don't cache that, or the account stays empty until relaunch.
        guard let loaded = try? credentials.load(for: accountId) else { return [] }
        cookieCache[accountId] = loaded
        return loaded
    }

    public func saveCookies(_ cookies: [HTTPCookie], for accountId: String) {
        let stored = CookiePolicy.filter(cookies).compactMap(StoredCookie.init)
        do {
            try credentials.save(stored, for: accountId)
            cookieCache[accountId] = stored
        } catch {
            NSLog("could not save credentials for \(accountId): \(error)")
            return
        }
        update(accountId) { $0.expiresAt = CookiePolicy.sessionExpiry(in: cookies) }
    }

    public var activeAccount: Account? {
        accounts.first { $0.id == activeAccountId }
    }

    @discardableResult
    public func upsertAccount(_ account: Account, cookies: [HTTPCookie]) throws -> Account {
        var updated = account
        updated.expiresAt = CookiePolicy.sessionExpiry(in: cookies)
        updated.consecutiveAuthFailures = 0

        let stored = CookiePolicy.filter(cookies).compactMap(StoredCookie.init)
        try credentials.save(stored, for: updated.id)
        cookieCache[updated.id] = stored

        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = updated
        } else {
            accounts.append(updated)
        }
        activeAccountId = updated.id

        persist()
        return updated
    }

    public func removeAccount(_ id: String) throws {
        try credentials.delete(for: id)
        cookieCache.removeValue(forKey: id)
        accounts.removeAll { $0.id == id }
        defaults.removeObject(forKey: "last_notified_threshold_\(id)")
        if activeAccountId == id { activeAccountId = accounts.first?.id }
        persist()
    }

    public func setName(_ name: String, for id: String) {
        update(id) { $0.name = name }
    }

    public func setActive(_ id: String) {
        guard accounts.contains(where: { $0.id == id }) else { return }
        activeAccountId = id
        persist()
    }

    public func update(_ id: String, transform: (inout Account) -> Void) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        transform(&accounts[index])
        persist()
    }

    public func state(for account: Account) -> SessionState {
        SessionStateEvaluator.evaluate(
            expiresAt: account.expiresAt,
            consecutiveAuthFailures: account.consecutiveAuthFailures,
            lastFetchFailedNonAuth: account.lastFetchFailedNonAuth
        )
    }
}