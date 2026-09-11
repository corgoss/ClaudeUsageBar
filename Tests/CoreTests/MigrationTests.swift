import XCTest
@testable import ClaudeUsageBarCore

final class MigrationTests: XCTestCase {

    func test_movesCookieOutOfAccountIntoCredentials() {
        let legacy = [LegacyAccount(id: "a1", name: "Work",
                                    cookie: "sessionKey=abc; lastActiveOrg=org-1",
                                    sessionPercentage: 42)]
        let result = Migration.migrate(legacy: legacy)

        XCTAssertEqual(result.accounts.count, 1)
        XCTAssertEqual(result.accounts[0].id, "a1")
        XCTAssertEqual(result.accounts[0].name, "Work")
        XCTAssertEqual(result.accounts[0].sessionPercentage, 42)
        XCTAssertEqual(result.credentials["a1"]?.map(\.name).sorted(),
                       ["lastActiveOrg", "sessionKey"])
    }

    func test_extractsOrgIdFromCookie() {
        let result = Migration.migrate(legacy: [
            LegacyAccount(id: "a1", name: "Work",
                          cookie: "sessionKey=abc; lastActiveOrg=org-1", sessionPercentage: nil)
        ])
        XCTAssertEqual(result.accounts[0].orgId, "org-1")
    }

    func test_expiryIsUnknownBecausePastedStringsCarryNoMetadata() {
        let result = Migration.migrate(legacy: [
            LegacyAccount(id: "a1", name: "Work", cookie: "sessionKey=abc", sessionPercentage: nil)
        ])
        XCTAssertNil(result.accounts[0].expiresAt)
    }

    func test_dropsCloudflareCookiesDuringMigration() {
        let result = Migration.migrate(legacy: [
            LegacyAccount(id: "a1", name: "Work",
                          cookie: "sessionKey=abc; cf_clearance=xyz; __cf_bm=q",
                          sessionPercentage: nil)
        ])
        XCTAssertEqual(result.credentials["a1"]?.map(\.name), ["sessionKey"])
    }

    func test_keepsAccountWithUnusableCookie() {
        let result = Migration.migrate(legacy: [
            LegacyAccount(id: "a1", name: "Work", cookie: "garbage", sessionPercentage: nil)
        ])
        XCTAssertEqual(result.accounts.count, 1)
        XCTAssertEqual(result.credentials["a1"] ?? [], [])
    }

    func test_migratesMultipleAccountsIndependently() {
        let result = Migration.migrate(legacy: [
            LegacyAccount(id: "a1", name: "Work", cookie: "sessionKey=one", sessionPercentage: nil),
            LegacyAccount(id: "a2", name: "Personal", cookie: "sessionKey=two", sessionPercentage: nil),
        ])
        XCTAssertEqual(result.credentials["a1"]?.first?.value, "one")
        XCTAssertEqual(result.credentials["a2"]?.first?.value, "two")
    }

    func test_emptyInputProducesEmptyResult() {
        let result = Migration.migrate(legacy: [])
        XCTAssertTrue(result.accounts.isEmpty)
        XCTAssertTrue(result.credentials.isEmpty)
    }
}