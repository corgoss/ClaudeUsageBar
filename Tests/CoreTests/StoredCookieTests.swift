import XCTest
@testable import ClaudeUsageBarCore

final class StoredCookieTests: XCTestCase {

    private func httpCookie(_ name: String, _ value: String, expires: Date? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: ".claude.ai", .path: "/", .name: name, .value: value,
        ]
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)!
    }

    func test_roundTripsThroughHTTPCookie() {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let stored = StoredCookie(httpCookie("sessionKey", "abc", expires: expiry))
        XCTAssertNotNil(stored)
        let rebuilt = stored?.httpCookie
        XCTAssertEqual(rebuilt?.name, "sessionKey")
        XCTAssertEqual(rebuilt?.value, "abc")
        XCTAssertEqual(rebuilt?.expiresDate, expiry)
    }

    func test_roundTripsThroughCodable() throws {
        let stored = StoredCookie(httpCookie("sessionKey", "abc"))!
        let data = try JSONEncoder().encode([stored])
        let decoded = try JSONDecoder().decode([StoredCookie].self, from: data)
        XCTAssertEqual(decoded, [stored])
    }

    func test_diff_detectsValueChange() {
        let before = [StoredCookie(httpCookie("sessionKey", "old"))!]
        let after = [StoredCookie(httpCookie("sessionKey", "new"))!]
        XCTAssertTrue(CookieDiff.changed(from: before, to: after))
    }

    func test_diff_detectsExpiryChange() {
        let before = [StoredCookie(httpCookie("sessionKey", "v",
                                              expires: Date(timeIntervalSince1970: 100)))!]
        let after = [StoredCookie(httpCookie("sessionKey", "v",
                                             expires: Date(timeIntervalSince1970: 999)))!]
        XCTAssertTrue(CookieDiff.changed(from: before, to: after))
    }

    func test_diff_ignoresOrdering() {
        let cookies = [StoredCookie(httpCookie("sessionKey", "v"))!,
                       StoredCookie(httpCookie("lastActiveOrg", "o"))!]
        XCTAssertFalse(CookieDiff.changed(from: cookies, to: cookies.reversed()))
    }

    func test_diff_detectsDisappearance() {
        let before = [StoredCookie(httpCookie("sessionKey", "v"))!,
                      StoredCookie(httpCookie("lastActiveOrg", "o"))!]
        let after = [StoredCookie(httpCookie("sessionKey", "v"))!]
        XCTAssertTrue(CookieDiff.changed(from: before, to: after))
    }

    func test_inMemoryStore_savesLoadsDeletes() throws {
        let store = InMemoryCredentialStore()
        let cookies = [StoredCookie(httpCookie("sessionKey", "abc"))!]
        XCTAssertEqual(try store.load(for: "acct-1"), [])
        try store.save(cookies, for: "acct-1")
        XCTAssertEqual(try store.load(for: "acct-1"), cookies)
        XCTAssertEqual(try store.load(for: "acct-2"), [])
        try store.delete(for: "acct-1")
        XCTAssertEqual(try store.load(for: "acct-1"), [])
    }
}