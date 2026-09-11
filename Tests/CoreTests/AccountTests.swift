import XCTest
@testable import ClaudeUsageBarCore

final class AccountTests: XCTestCase {
    func test_missingTransientFailureFieldDefaultsToFalse() throws {
        let data = Data("""
        {
          "id": "acct-1",
          "name": "Work",
          "consecutiveAuthFailures": 0
        }
        """.utf8)

        let account = try JSONDecoder().decode(Account.self, from: data)
        XCTAssertFalse(account.lastFetchFailedNonAuth)
    }
}