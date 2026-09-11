import XCTest
@testable import ClaudeUsageBarCore

final class LoginCompletionTests: XCTestCase {
    private enum PersistenceError: Error {
        case unavailable
    }

    func test_persistThenClose_closesOnlyAfterCredentialsAreSaved() {
        var events: [String] = []

        let result = LoginCompletion.persistThenClose(
            persist: { events.append("persist") },
            close: { events.append("close") }
        )

        guard case .success = result else {
            return XCTFail("Expected successful credential persistence")
        }
        XCTAssertEqual(events, ["persist", "close"])
    }

    func test_persistThenClose_keepsLoginOpenWhenCredentialsCannotBeSaved() {
        var didClose = false

        let result = LoginCompletion.persistThenClose(
            persist: { throw PersistenceError.unavailable },
            close: { didClose = true }
        )

        guard case .failure = result else {
            return XCTFail("Expected credential persistence failure")
        }
        XCTAssertFalse(didClose)
    }
}