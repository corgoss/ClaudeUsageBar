import XCTest
@testable import ClaudeUsageBarCore

final class CookiePolicyTests: XCTestCase {

    private func cookie(_ name: String, _ value: String = "v") -> HTTPCookie {
        HTTPCookie(properties: [
            .domain: ".claude.ai", .path: "/", .name: name, .value: value,
        ])!
    }

    func test_filter_keepsSessionBearingCookies() {
        let kept = CookiePolicy.filter([cookie("sessionKey"), cookie("lastActiveOrg")])
        XCTAssertEqual(kept.map(\.name).sorted(), ["lastActiveOrg", "sessionKey"])
    }

    func test_filter_dropsCloudflareCookies() {
        let kept = CookiePolicy.filter([
            cookie("sessionKey"), cookie("cf_clearance"),
            cookie("__cf_bm"), cookie("_cfuvid"),
        ])
        XCTAssertEqual(kept.map(\.name), ["sessionKey"])
    }

    func test_filter_dropsAnalyticsCookies() {
        let kept = CookiePolicy.filter([
            cookie("sessionKey"), cookie("_fbp"), cookie("ajs_anonymous_id"),
            cookie("_dd_s_v2"), cookie("g_state"), cookie("__ssid"),
        ])
        XCTAssertEqual(kept.map(\.name), ["sessionKey"])
    }

    func test_parse_extractsAllowlistedPairs() {
        let parsed = CookiePolicy.parse(pasted: "sessionKey=abc; lastActiveOrg=org-1; _fbp=junk")
        XCTAssertEqual(parsed.map(\.name).sorted(), ["lastActiveOrg", "sessionKey"])
        XCTAssertEqual(parsed.first { $0.name == "sessionKey" }?.value, "abc")
    }

    func test_parse_preservesEqualsSignsInsideValue() {
        let parsed = CookiePolicy.parse(pasted: "sessionKey=sk-ant-sid01-aa==")
        XCTAssertEqual(parsed.first?.value, "sk-ant-sid01-aa==")
    }

    func test_parse_toleratesCookieHeaderPrefix() {
        let parsed = CookiePolicy.parse(pasted: "Cookie: sessionKey=abc")
        XCTAssertEqual(parsed.first?.value, "abc")
    }

    func test_parse_ignoresMalformedAndEmptyInput() {
        XCTAssertTrue(CookiePolicy.parse(pasted: "").isEmpty)
        XCTAssertTrue(CookiePolicy.parse(pasted: "garbage; ;; sessionKey=").isEmpty)
    }

    func test_sessionExpiry_readsSessionKeyOnly() {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let sessionKey = HTTPCookie(properties: [
            .domain: ".claude.ai", .path: "/", .name: "sessionKey",
            .value: "v", .expires: expiry,
        ])!
        XCTAssertEqual(CookiePolicy.sessionExpiry(in: [sessionKey, cookie("lastActiveOrg")]), expiry)
        XCTAssertNil(CookiePolicy.sessionExpiry(in: [cookie("lastActiveOrg")]))
    }
}