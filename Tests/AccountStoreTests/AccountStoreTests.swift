import XCTest
@testable import ClaudeUsageBarAuth
import ClaudeUsageBarCore

final class AccountStoreTests: XCTestCase {
    private enum CredentialError: Error {
        case unavailable
    }

    private final class FailingCredentialStore: CredentialStore {
        func save(_ cookies: [StoredCookie], for accountId: String) throws {
            throw CredentialError.unavailable
        }

        func load(for accountId: String) throws -> [StoredCookie] {
            []
        }

        func delete(for accountId: String) throws {}
    }

    func test_upsertAccount_doesNotPersistMetadataWhenCredentialsCannotBeSaved() {
        let suiteName = "AccountStoreTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AccountStore(credentials: FailingCredentialStore(), defaults: defaults)
        let account = Account(id: "acct-1", name: "Work")
        let cookies = [HTTPCookie(properties: [
            .domain: ".claude.ai", .path: "/", .name: "sessionKey", .value: "secret",
        ])!]

        XCTAssertThrowsError(try store.upsertAccount(account, cookies: cookies))
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertNil(store.activeAccountId)
        XCTAssertNil(defaults.data(forKey: "accounts_v3"))
        XCTAssertNil(defaults.string(forKey: "active_account_id"))
    }

    private final class CountingCredentialStore: CredentialStore {
        private(set) var loadCount = 0
        private var storage: [String: [StoredCookie]] = [:]

        init(seed: [String: [StoredCookie]] = [:]) {
            storage = seed
        }

        func save(_ cookies: [StoredCookie], for accountId: String) throws {
            storage[accountId] = cookies
        }

        func load(for accountId: String) throws -> [StoredCookie] {
            loadCount += 1
            return storage[accountId] ?? []
        }

        func delete(for accountId: String) throws {
            storage.removeValue(forKey: accountId)
        }
    }

    private func isolatedDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "AccountStoreTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }

    private func cookie(_ name: String, _ value: String) -> HTTPCookie {
        HTTPCookie(properties: [
            .domain: ".claude.ai", .path: "/", .name: name, .value: value,
        ])!
    }

    func test_cookies_readsCredentialStoreOnlyOncePerAccount() {
        isolatedDefaults { defaults in
            let credentials = CountingCredentialStore(
                seed: ["acct-1": [StoredCookie(name: "sessionKey", value: "secret")]]
            )
            let store = AccountStore(credentials: credentials, defaults: defaults)

            for _ in 0..<5 {
                XCTAssertEqual(store.cookies(for: "acct-1").first?.value, "secret")
            }

            XCTAssertEqual(credentials.loadCount, 1,
                           "repeated reads must be served from memory, not the keychain")
        }
    }

    func test_saveCookies_updatesCachedValueWithoutRereading() {
        isolatedDefaults { defaults in
            let credentials = CountingCredentialStore()
            let store = AccountStore(credentials: credentials, defaults: defaults)
            _ = try? store.upsertAccount(Account(id: "acct-1", name: "Work"),
                                         cookies: [cookie("sessionKey", "first")])

            store.saveCookies([cookie("sessionKey", "second")], for: "acct-1")

            XCTAssertEqual(store.cookies(for: "acct-1").first?.value, "second")
            XCTAssertEqual(credentials.loadCount, 0,
                           "writes should seed the cache, never trigger a keychain read")
        }
    }

    func test_removeAccount_dropsCachedCookies() {
        isolatedDefaults { defaults in
            let credentials = CountingCredentialStore()
            let store = AccountStore(credentials: credentials, defaults: defaults)
            _ = try? store.upsertAccount(Account(id: "acct-1", name: "Work"),
                                         cookies: [cookie("sessionKey", "secret")])
            try? store.removeAccount("acct-1")

            XCTAssertTrue(store.cookies(for: "acct-1").isEmpty,
                          "removed accounts must not be served from a stale cache")
        }
    }
}
