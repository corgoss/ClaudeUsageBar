# Account Sign-In & Session Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the DevTools cookie-paste login with an embedded claude.ai sign-in window, move credentials to the Keychain, and give each account an isolated, self-persisting session with proactive expiry warnings.

**Architecture:** Pure logic (cookie allowlist, state derivation, migration) lives in `app/Core` behind a Foundation-only boundary so it is unit-testable headlessly via SPM. Platform code (Keychain, URLSession, WebKit, AppKit) lives in `app/Auth` and `app/UI` and is verified by a manual checklist. The existing `UsageManager` keeps its role but delegates all credential and transport concerns to `AccountStore` and `ClaudeSession`.

**Tech Stack:** Swift 6.3, SwiftUI, AppKit, WebKit, Security.framework, XCTest via SwiftPM. macOS 12.0 deployment target. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-09-11-account-session-management-design.md`

## Global Constraints

- macOS deployment target is **12.0** (`LSMinimumSystemVersion` in `app/Info.plist`). Do not use API newer than macOS 12 — notably **not** `WKWebsiteDataStore(forIdentifier:)`, which is macOS 14+.
- **Never set the `Cookie` HTTP header manually.** All cookie attachment goes through a `URLSession` cookie jar. This is the core defect being fixed.
- **Never store or transmit Cloudflare cookies** (`cf_clearance`, `__cf_bm`, `_cfuvid`) or analytics cookies. Allowlist only.
- One User-Agent constant shared by the native session and every `WKWebView`: `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Safari/605.1.15`
- Org ID comes from the `lastActiveOrg` cookie. **Never** from `/api/bootstrap`'s `account.lastActiveOrgId` — that key no longer exists.
- Stored credentials are **never deleted on a fetch failure**. Only explicit account removal or a successful re-login replaces them.
- No third-party dependencies.
- `app/Core` must import **only** Foundation. Any AppKit/WebKit/Security import there is a bug.

---

### Task 1: CookiePolicy, test harness, and build glob

Establishes the testable core. Includes the SPM scaffolding and `build.sh` change because nothing else can compile from a subdirectory until they exist.

**Files:**
- Create: `Package.swift`
- Create: `app/Core/CookiePolicy.swift`
- Create: `Tests/CoreTests/CookiePolicyTests.swift`
- Modify: `app/build.sh` (the two `swiftc` invocations, lines 37-51)

**Interfaces:**
- Consumes: nothing
- Produces: `CookiePolicy.allowlist: Set<String>`, `CookiePolicy.filter([HTTPCookie]) -> [HTTPCookie]`, `CookiePolicy.parse(pasted: String) -> [HTTPCookie]`, `CookiePolicy.sessionExpiry(in: [HTTPCookie]) -> Date?`

- [ ] **Step 1: Create the SPM manifest**

Create `Package.swift` at the repo root:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeUsageBarCore",
    platforms: [.macOS(.v12)],
    targets: [
        .target(name: "ClaudeUsageBarCore", path: "app/Core"),
        .testTarget(
            name: "CoreTests",
            dependencies: ["ClaudeUsageBarCore"],
            path: "Tests/CoreTests"
        ),
    ]
)
```

- [ ] **Step 2: Write the failing test**

Create `Tests/CoreTests/CookiePolicyTests.swift`:

```swift
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
        // Base64-ish tokens contain '='. Only the FIRST '=' separates name from value.
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
        let sk = HTTPCookie(properties: [
            .domain: ".claude.ai", .path: "/", .name: "sessionKey",
            .value: "v", .expires: expiry,
        ])!
        XCTAssertEqual(CookiePolicy.sessionExpiry(in: [sk, cookie("lastActiveOrg")]), expiry)
        XCTAssertNil(CookiePolicy.sessionExpiry(in: [cookie("lastActiveOrg")]))
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --filter CookiePolicyTests`
Expected: FAIL — `cannot find 'CookiePolicy' in scope`.

- [ ] **Step 4: Write the implementation**

Create `app/Core/CookiePolicy.swift`:

```swift
import Foundation

/// Decides which claude.ai cookies are worth keeping and sending.
///
/// This is an allowlist, not a blocklist. Cloudflare cookies (`cf_clearance`,
/// `__cf_bm`, `_cfuvid`) are deliberately excluded: a spike on 2026-09-11
/// proved the usage API returns 200 without them, and carrying them alongside
/// a non-matching User-Agent is what produced the app's unexplained 403s.
public enum CookiePolicy {

    public static let allowlist: Set<String> = [
        "sessionKey",           // the credential
        "sessionKeyLC",
        "lastActiveOrg",        // org id — the only reliable source
        "routingHint",          // load-balancer affinity
        "anthropic-device-id",
    ]

    public static func filter(_ cookies: [HTTPCookie]) -> [HTTPCookie] {
        cookies.filter { allowlist.contains($0.name) }
    }

    /// Parses a legacy pasted `Cookie:` header value into cookies for claude.ai.
    /// Used only by migration; pasted strings carry no expiry metadata.
    public static func parse(pasted: String) -> [HTTPCookie] {
        var input = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.lowercased().hasPrefix("cookie:") {
            input = String(input.dropFirst("cookie:".count))
        }

        return input.components(separatedBy: ";").compactMap { part in
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            // Split on the FIRST '=' only: token values legitimately contain '='.
            guard let separator = trimmed.firstIndex(of: "=") else { return nil }
            let name = String(trimmed[trimmed.startIndex..<separator])
            let value = String(trimmed[trimmed.index(after: separator)...])
            guard allowlist.contains(name), !value.isEmpty else { return nil }

            return HTTPCookie(properties: [
                .domain: ".claude.ai",
                .path: "/",
                .name: name,
                .value: value,
                .secure: true,
            ])
        }
    }

    public static func sessionExpiry(in cookies: [HTTPCookie]) -> Date? {
        cookies.first { $0.name == "sessionKey" }?.expiresDate
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --filter CookiePolicyTests`
Expected: PASS, 8 tests.

- [ ] **Step 6: Update build.sh to compile subdirectories**

A flat `*.swift` glob does not recurse, so collect sources explicitly. In `app/build.sh`, immediately before the first `swiftc` invocation, add:

```sh
# Collect all sources; the app is no longer a single file.
SOURCES=$(find . -name '*.swift' -not -path './build/*' -not -path './.build/*')
```

Then in **both** `swiftc` invocations replace the literal `ClaudeUsageBar.swift` argument with `$SOURCES` (unquoted, so it word-splits):

```sh
swiftc -parse-as-library -o "$APP_PATH/Contents/MacOS/ClaudeUsageBar_arm64" \
    $SOURCES \
    -framework SwiftUI \
    -framework AppKit \
    -framework WebKit \
    -target arm64-apple-macos12.0
```

- [ ] **Step 7: Verify the app still builds**

Run: `cd app && ./build.sh`
Expected: "Build successful!" — `app/Core/CookiePolicy.swift` is now compiled into the app as well as the test library.

Note: `build.sh` ends by launching the app. Quit it from the menu bar before continuing.

- [ ] **Step 8: Commit**

```bash
git add Package.swift app/Core/CookiePolicy.swift Tests/CoreTests/CookiePolicyTests.swift app/build.sh
git commit -m "feat: add CookiePolicy allowlist with SPM test harness"
```

---

### Task 2: SessionState derivation

The pure decision ladder from spec §6. Highest-value unit tests in the plan.

**Files:**
- Create: `app/Core/SessionState.swift`
- Create: `Tests/CoreTests/SessionStateTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `SessionState` enum (`.healthy`, `.expiringSoon(daysRemaining: Int)`, `.needsSignIn`, `.temporarilyUnavailable`); `SessionStateEvaluator.evaluate(expiresAt:consecutiveAuthFailures:lastFetchFailedNonAuth:now:) -> SessionState`; `SessionStateEvaluator.shouldAttemptRenewal(expiresAt:lastRenewalAttempt:now:) -> Bool`

- [ ] **Step 1: Write the failing test**

Create `Tests/CoreTests/SessionStateTests.swift`:

```swift
import XCTest
@testable import ClaudeUsageBarCore

final class SessionStateTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func days(_ n: Int) -> Date { now.addingTimeInterval(Double(n) * 86_400) }

    func test_healthy_whenExpiryIsFarAway() {
        XCTAssertEqual(
            SessionStateEvaluator.evaluate(expiresAt: days(28), consecutiveAuthFailures: 0,
                                           lastFetchFailedNonAuth: false, now: now),
            .healthy)
    }

    func test_expiringSoon_atThreeDaysOrLess() {
        XCTAssertEqual(
            SessionStateEvaluator.evaluate(expiresAt: days(3), consecutiveAuthFailures: 0,
                                           lastFetchFailedNonAuth: false, now: now),
            .expiringSoon(daysRemaining: 3))
    }

    func test_stillHealthy_atFourDays() {
        XCTAssertEqual(
            SessionStateEvaluator.evaluate(expiresAt: days(4), consecutiveAuthFailures: 0,
                                           lastFetchFailedNonAuth: false, now: now),
            .healthy)
    }

    func test_needsSignIn_whenExpired() {
        XCTAssertEqual(
            SessionStateEvaluator.evaluate(expiresAt: days(-1), consecutiveAuthFailures: 0,
                                           lastFetchFailedNonAuth: false, now: now),
            .needsSignIn)
    }

    func test_needsSignIn_afterTwoAuthFailures() {
        XCTAssertEqual(
            SessionStateEvaluator.evaluate(expiresAt: days(28), consecutiveAuthFailures: 2,
                                           lastFetchFailedNonAuth: false, now: now),
            .needsSignIn)
    }

    func test_singleAuthFailure_doesNotDemandSignIn() {
        XCTAssertEqual(
            SessionStateEvaluator.evaluate(expiresAt: days(28), consecutiveAuthFailures: 1,
                                           lastFetchFailedNonAuth: false, now: now),
            .healthy)
    }

    func test_temporarilyUnavailable_onNonAuthFailure() {
        XCTAssertEqual(
            SessionStateEvaluator.evaluate(expiresAt: days(28), consecutiveAuthFailures: 0,
                                           lastFetchFailedNonAuth: true, now: now),
            .temporarilyUnavailable)
    }

    // Migrated accounts have no expiry metadata; they must not look broken.
    func test_unknownExpiry_isHealthy() {
        XCTAssertEqual(
            SessionStateEvaluator.evaluate(expiresAt: nil, consecutiveAuthFailures: 0,
                                           lastFetchFailedNonAuth: false, now: now),
            .healthy)
    }

    // Precedence: an actionable expiry warning outranks a transient network blip.
    func test_expiringSoon_outranksNetworkFailure() {
        XCTAssertEqual(
            SessionStateEvaluator.evaluate(expiresAt: days(2), consecutiveAuthFailures: 0,
                                           lastFetchFailedNonAuth: true, now: now),
            .expiringSoon(daysRemaining: 2))
    }

    func test_renewal_attemptedInsideSevenDayWindow() {
        XCTAssertTrue(SessionStateEvaluator.shouldAttemptRenewal(
            expiresAt: days(5), lastRenewalAttempt: nil, now: now))
    }

    func test_renewal_notAttemptedOutsideWindow() {
        XCTAssertFalse(SessionStateEvaluator.shouldAttemptRenewal(
            expiresAt: days(20), lastRenewalAttempt: nil, now: now))
    }

    func test_renewal_rateLimitedToOncePerDay() {
        XCTAssertFalse(SessionStateEvaluator.shouldAttemptRenewal(
            expiresAt: days(5), lastRenewalAttempt: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(SessionStateEvaluator.shouldAttemptRenewal(
            expiresAt: days(5), lastRenewalAttempt: now.addingTimeInterval(-25 * 3600), now: now))
    }

    func test_renewal_notAttemptedWhenAlreadyExpiredOrUnknown() {
        XCTAssertFalse(SessionStateEvaluator.shouldAttemptRenewal(
            expiresAt: days(-1), lastRenewalAttempt: nil, now: now))
        XCTAssertFalse(SessionStateEvaluator.shouldAttemptRenewal(
            expiresAt: nil, lastRenewalAttempt: nil, now: now))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter SessionStateTests`
Expected: FAIL — `cannot find 'SessionStateEvaluator' in scope`.

- [ ] **Step 3: Write the implementation**

Create `app/Core/SessionState.swift`:

```swift
import Foundation

public enum SessionState: Equatable {
    case healthy
    case expiringSoon(daysRemaining: Int)   // <= 3 days
    case needsSignIn                        // expired, or auth rejected twice
    case temporarilyUnavailable             // network / 5xx — do not alarm
}

/// Derives per-account session state. Pure by design: this is the decision
/// ladder from the design doc, and the piece most worth testing.
public enum SessionStateEvaluator {

    private static let expiringSoonThresholdDays = 3
    private static let renewalWindowDays = 7
    private static let renewalCooldown: TimeInterval = 24 * 3600

    private static func fullDaysBetween(_ from: Date, _ to: Date) -> Int {
        Calendar.current.dateComponents([.day], from: from, to: to).day ?? 0
    }

    /// Precedence, highest first:
    ///   1. repeated auth rejection  2. expired  3. expiring soon
    ///   4. transient failure        5. healthy
    /// An expiry warning outranks a network blip because it is actionable.
    /// A nil `expiresAt` (migrated accounts) is treated as healthy and left to
    /// the reactive ladder to correct.
    public static func evaluate(expiresAt: Date?,
                                consecutiveAuthFailures: Int,
                                lastFetchFailedNonAuth: Bool,
                                now: Date = Date()) -> SessionState {
        if consecutiveAuthFailures >= 2 { return .needsSignIn }

        if let expiresAt {
            if expiresAt <= now { return .needsSignIn }
            let remaining = fullDaysBetween(now, expiresAt)
            if remaining <= expiringSoonThresholdDays {
                return .expiringSoon(daysRemaining: max(0, remaining))
            }
        }

        if lastFetchFailedNonAuth { return .temporarilyUnavailable }
        return .healthy
    }

    /// A silent renewal is worth attempting only near expiry — the one window
    /// where a server-side sliding refresh, if it exists at all, would fire.
    public static func shouldAttemptRenewal(expiresAt: Date?,
                                            lastRenewalAttempt: Date?,
                                            now: Date = Date()) -> Bool {
        guard let expiresAt, expiresAt > now else { return false }
        guard fullDaysBetween(now, expiresAt) <= renewalWindowDays else { return false }
        if let last = lastRenewalAttempt, now.timeIntervalSince(last) < renewalCooldown {
            return false
        }
        return true
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter SessionStateTests`
Expected: PASS, 13 tests.

- [ ] **Step 5: Commit**

```bash
git add app/Core/SessionState.swift Tests/CoreTests/SessionStateTests.swift
git commit -m "feat: add session state derivation ladder"
```

---

### Task 3: Account model, StoredCookie, and CredentialStore protocol

Defines the data shapes every later task depends on, plus an in-memory credential store so tests never touch the real Keychain.

**Files:**
- Create: `app/Core/Account.swift`
- Create: `app/Core/CredentialStore.swift`
- Create: `Tests/CoreTests/StoredCookieTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `Account` struct; `StoredCookie` struct with `init?(_ HTTPCookie)` and `var httpCookie: HTTPCookie?`; `CredentialStore` protocol with `save(_:for:)`, `load(for:)`, `delete(for:)`; `InMemoryCredentialStore`; `CookieDiff.changed(from:to:) -> Bool`

- [ ] **Step 1: Write the failing test**

Create `Tests/CoreTests/StoredCookieTests.swift`:

```swift
import XCTest
@testable import ClaudeUsageBarCore

final class StoredCookieTests: XCTestCase {

    private func httpCookie(_ name: String, _ value: String, expires: Date? = nil) -> HTTPCookie {
        var props: [HTTPCookiePropertyKey: Any] = [
            .domain: ".claude.ai", .path: "/", .name: name, .value: value,
        ]
        if let expires { props[.expires] = expires }
        return HTTPCookie(properties: props)!
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
        let a = [StoredCookie(httpCookie("sessionKey", "v"))!,
                 StoredCookie(httpCookie("lastActiveOrg", "o"))!]
        XCTAssertFalse(CookieDiff.changed(from: a, to: a.reversed()))
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
        XCTAssertEqual(try store.load(for: "acct-2"), [])   // isolation
        try store.delete(for: "acct-1")
        XCTAssertEqual(try store.load(for: "acct-1"), [])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter StoredCookieTests`
Expected: FAIL — `cannot find 'StoredCookie' in scope`.

- [ ] **Step 3: Write the Account model**

Create `app/Core/Account.swift`:

```swift
import Foundation

/// A configured Claude account. Carries NO secrets — cookies live in the
/// credential store, keyed by `id`. This struct is what gets persisted to
/// UserDefaults.
public struct Account: Identifiable, Codable, Equatable {
    public let id: String                  // stable UUID; keys credentials + thresholds
    public var name: String                // user label, auto-filled from email
    public var email: String?              // identity check on re-login
    public var orgId: String?              // from the lastActiveOrg cookie
    public var sessionPercentage: Int?
    public var expiresAt: Date?            // sessionKey expiry; nil after migration
    public var lastSuccessfulFetch: Date?
    public var lastRenewalAttempt: Date?
    public var consecutiveAuthFailures: Int

    public init(id: String = UUID().uuidString,
                name: String,
                email: String? = nil,
                orgId: String? = nil,
                sessionPercentage: Int? = nil,
                expiresAt: Date? = nil,
                lastSuccessfulFetch: Date? = nil,
                lastRenewalAttempt: Date? = nil,
                consecutiveAuthFailures: Int = 0) {
        self.id = id
        self.name = name
        self.email = email
        self.orgId = orgId
        self.sessionPercentage = sessionPercentage
        self.expiresAt = expiresAt
        self.lastSuccessfulFetch = lastSuccessfulFetch
        self.lastRenewalAttempt = lastRenewalAttempt
        self.consecutiveAuthFailures = consecutiveAuthFailures
    }

    /// Older persisted records lack the newer fields; decode them as defaults
    /// so a single `accounts_v3` blob survives forward changes.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        orgId = try c.decodeIfPresent(String.self, forKey: .orgId)
        sessionPercentage = try c.decodeIfPresent(Int.self, forKey: .sessionPercentage)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        lastSuccessfulFetch = try c.decodeIfPresent(Date.self, forKey: .lastSuccessfulFetch)
        lastRenewalAttempt = try c.decodeIfPresent(Date.self, forKey: .lastRenewalAttempt)
        consecutiveAuthFailures =
            try c.decodeIfPresent(Int.self, forKey: .consecutiveAuthFailures) ?? 0
    }
}
```

- [ ] **Step 4: Write StoredCookie, CookieDiff, and the store protocol**

Create `app/Core/CredentialStore.swift`:

```swift
import Foundation

/// A cookie in a form that survives JSON encoding into the Keychain.
/// `HTTPCookie` itself is not `Codable`, hence this shape.
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
        var props: [HTTPCookiePropertyKey: Any] = [
            .domain: domain, .path: path, .name: name, .value: value,
        ]
        if let expiresAt { props[.expires] = expiresAt }
        if isSecure { props[.secure] = true }
        return HTTPCookie(properties: props)
    }
}

public enum CookieDiff {
    /// Order-independent comparison by (name -> value+expiry).
    public static func changed(from old: [StoredCookie], to new: [StoredCookie]) -> Bool {
        func key(_ cookies: [StoredCookie]) -> [String: String] {
            Dictionary(cookies.map {
                ($0.name, "\($0.value)|\($0.expiresAt?.timeIntervalSince1970 ?? -1)")
            }, uniquingKeysWith: { a, _ in a })
        }
        return key(old) != key(new)
    }
}

public protocol CredentialStore: AnyObject {
    func save(_ cookies: [StoredCookie], for accountId: String) throws
    /// Returns `[]` for an unknown account rather than throwing.
    func load(for accountId: String) throws -> [StoredCookie]
    func delete(for accountId: String) throws
}

/// Test double. Never used by the app.
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
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --filter StoredCookieTests`
Expected: PASS, 7 tests.

- [ ] **Step 6: Commit**

```bash
git add app/Core/Account.swift app/Core/CredentialStore.swift Tests/CoreTests/StoredCookieTests.swift
git commit -m "feat: add Account model, StoredCookie, and credential store protocol"
```

---

### Task 4: Migration from the legacy plaintext plist

Pure transform, so the riskiest data change in the project is fully tested before it touches a real user's plist.

**Files:**
- Create: `app/Core/Migration.swift`
- Create: `Tests/CoreTests/MigrationTests.swift`

**Interfaces:**
- Consumes: `Account`, `StoredCookie`, `CookiePolicy` (Tasks 1, 3)
- Produces: `LegacyAccount` struct; `MigrationResult` struct with `.accounts: [Account]` and `.credentials: [String: [StoredCookie]]`; `Migration.migrate(legacy:) -> MigrationResult`

- [ ] **Step 1: Write the failing test**

Create `Tests/CoreTests/MigrationTests.swift`:

```swift
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

    // An account whose cookie yields nothing usable is kept, not silently
    // deleted — the user re-signs in rather than losing the row.
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter MigrationTests`
Expected: FAIL — `cannot find 'LegacyAccount' in scope`.

- [ ] **Step 3: Write the implementation**

Create `app/Core/Migration.swift`:

```swift
import Foundation

/// The pre-Keychain shape persisted under the `accounts_v2` UserDefaults key.
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
    /// Splits legacy records into secret-free `Account`s plus credentials to be
    /// written to the Keychain.
    ///
    /// Pasted cookie strings carry no expiry metadata, so `expiresAt` stays nil
    /// and the UI must show "expiry unknown" rather than invent a countdown.
    /// Accounts whose cookie yields nothing usable are preserved with empty
    /// credentials so the user can re-sign in instead of losing the row.
    public static func migrate(legacy: [LegacyAccount]) -> MigrationResult {
        var accounts: [Account] = []
        var credentials: [String: [StoredCookie]] = [:]

        for record in legacy {
            let cookies = CookiePolicy.parse(pasted: record.cookie)
            credentials[record.id] = cookies.compactMap(StoredCookie.init)

            accounts.append(Account(
                id: record.id,
                name: record.name,
                email: nil,
                orgId: cookies.first { $0.name == "lastActiveOrg" }?.value,
                sessionPercentage: record.sessionPercentage,
                expiresAt: nil
            ))
        }

        return MigrationResult(accounts: accounts, credentials: credentials)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter MigrationTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: PASS, 35 tests across four test classes.

- [ ] **Step 6: Commit**

```bash
git add app/Core/Migration.swift Tests/CoreTests/MigrationTests.swift
git commit -m "feat: add legacy plist to keychain migration transform"
```

---
### Task 5: KeychainStore

The real credential store. Verified by an ad-hoc check binary against a throwaway service name so it never touches production items.

**Files:**
- Create: `app/Auth/KeychainStore.swift`
- Create: `scripts/keychain_check/main.swift` (verification harness, committed)

**Interfaces:**
- Consumes: `CredentialStore`, `StoredCookie` (Task 3)
- Produces: `KeychainStore(service:)` conforming to `CredentialStore`; `KeychainError.status(OSStatus)`

- [ ] **Step 1: Write the verification harness**

Create `scripts/keychain_check/main.swift` (the name matters: top-level code is only legal in a file called `main.swift`):

```swift
// Ad-hoc verification for KeychainStore. Compiled against the real sources
// with a throwaway service name so production credentials are never touched.
// Run via scripts/keychain_check.sh
import Foundation

let store = KeychainStore(service: "com.claude.usagebar.keychaincheck")
let accountId = "check-\(UUID().uuidString)"
let other = "check-\(UUID().uuidString)"
var failures = 0

func expect(_ condition: Bool, _ label: String) {
    print((condition ? "  PASS  " : "  FAIL  ") + label)
    if !condition { failures += 1 }
}

do {
    expect(try store.load(for: accountId).isEmpty, "unknown account loads as empty, not an error")

    let cookies = [
        StoredCookie(name: "sessionKey", value: "secret-value",
                     expiresAt: Date(timeIntervalSince1970: 1_800_000_000)),
        StoredCookie(name: "lastActiveOrg", value: "org-1"),
    ]
    try store.save(cookies, for: accountId)
    expect(try store.load(for: accountId) == cookies, "round-trips saved cookies")

    expect(try store.load(for: other).isEmpty, "accounts are isolated from each other")

    try store.save([StoredCookie(name: "sessionKey", value: "replaced")], for: accountId)
    let replaced = try store.load(for: accountId)
    expect(replaced.count == 1 && replaced.first?.value == "replaced", "save replaces, never appends")

    try store.delete(for: accountId)
    expect(try store.load(for: accountId).isEmpty, "delete removes the item")

    try store.delete(for: accountId)   // must not throw
    expect(true, "deleting a missing item is a no-op")
} catch {
    print("  FAIL  threw: \(error)")
    failures += 1
}

print(failures == 0 ? "\nALL KEYCHAIN CHECKS PASSED" : "\n\(failures) KEYCHAIN CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
```

- [ ] **Step 2: Write the runner script**

Create `scripts/keychain_check.sh` and make it executable (`chmod +x scripts/keychain_check.sh`):

```sh
#!/bin/bash
# Compiles KeychainStore plus its Core dependency with an ad-hoc main and runs it.
set -e
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)/keychain_check
swiftc -o "$OUT" \
    app/Core/CredentialStore.swift \
    app/Auth/KeychainStore.swift \
    scripts/keychain_check/main.swift \
    -framework Foundation
"$OUT"
```

Note: `app/Core/CredentialStore.swift` declares `public` symbols; compiling it into the same module as the check makes them visible without an import.

- [ ] **Step 3: Run the check to verify it fails**

Run: `./scripts/keychain_check.sh`
Expected: FAIL — `cannot find 'KeychainStore' in scope`.

- [ ] **Step 4: Write the implementation**

Create `app/Auth/KeychainStore.swift`:

```swift
import Foundation
import Security

public enum KeychainError: Error, CustomStringConvertible {
    case status(OSStatus)
    public var description: String {
        switch self {
        case .status(let s):
            let message = SecCopyErrorMessageString(s, nil) as String? ?? "unknown"
            return "Keychain error \(s): \(message)"
        }
    }
}

/// Stores per-account claude.ai cookies as a JSON blob in the login Keychain.
///
/// Accessibility is `WhenUnlocked`: the app only refreshes while the user is
/// logged in, so the stricter class costs nothing.
public final class KeychainStore: CredentialStore {

    private let service: String

    public init(service: String = "com.claude.usagebar.session") {
        self.service = service
    }

    private func baseQuery(_ accountId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId,
        ]
    }

    public func save(_ cookies: [StoredCookie], for accountId: String) throws {
        let data = try JSONEncoder().encode(cookies)

        // Delete-then-add keeps this a replace, never an append, and avoids
        // having to branch on whether the item already exists.
        SecItemDelete(baseQuery(accountId) as CFDictionary)

        var attributes = baseQuery(accountId)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public func load(for accountId: String) throws -> [StoredCookie] {
        var query = baseQuery(accountId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        guard let data = item as? Data else { return [] }

        return (try? JSONDecoder().decode([StoredCookie].self, from: data)) ?? []
    }

    public func delete(for accountId: String) throws {
        let status = SecItemDelete(baseQuery(accountId) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }
}
```

- [ ] **Step 5: Run the check to verify it passes**

Run: `./scripts/keychain_check.sh`
Expected: `ALL KEYCHAIN CHECKS PASSED`, 6 PASS lines.

If macOS prompts for keychain access, allow it — ad-hoc-compiled binaries have a different code identity than the signed app.

- [ ] **Step 6: Commit**

```bash
git add app/Auth/KeychainStore.swift scripts/keychain_check/main.swift scripts/keychain_check.sh
git commit -m "feat: add Keychain-backed credential store"
```

---

### Task 6: ClaudeSession

The transport fix. Its whole purpose is that cookies are attached by the jar, never by hand, so `Set-Cookie` can be captured.

**Files:**
- Create: `app/Auth/ClaudeSession.swift`
- Create: `scripts/session_check/main.swift`
- Create: `scripts/session_check.sh`

**Interfaces:**
- Consumes: `CookiePolicy`, `StoredCookie`, `CookieDiff` (Tasks 1, 3)
- Produces: `ClaudeSession(accountId:cookies:)`; `ClaudeSession.userAgent: String`; `session.get(path:completion:)` with `Result<Data, SessionError>`; `session.currentCookies: [HTTPCookie]`; `session.sessionKeyExpiry: Date?`; `session.onCookiesChanged: (([HTTPCookie]) -> Void)?`; `SessionError` enum; `ClaudeSession.makeRequest(path:) -> URLRequest`

- [ ] **Step 1: Write the verification harness**

Create `scripts/session_check/main.swift` (the name matters: top-level code is only legal in a file called `main.swift`). These assertions need no network — they guard the plan's central constraint:

```swift
// Ad-hoc verification that ClaudeSession never hand-sets a Cookie header
// and always carries the shared User-Agent. Run via scripts/session_check.sh
import Foundation

var failures = 0
func expect(_ condition: Bool, _ label: String) {
    print((condition ? "  PASS  " : "  FAIL  ") + label)
    if !condition { failures += 1 }
}

let cookie = HTTPCookie(properties: [
    .domain: ".claude.ai", .path: "/", .name: "sessionKey", .value: "secret",
])!
let session = ClaudeSession(accountId: "check", cookies: [cookie])
let request = session.makeRequest(path: "/api/organizations/org-1/usage")

expect(request.allHTTPHeaderFields?["Cookie"] == nil,
       "no manual Cookie header — the jar must attach cookies")
expect(request.value(forHTTPHeaderField: "User-Agent") == ClaudeSession.userAgent,
       "carries the shared User-Agent")
expect(request.url?.absoluteString == "https://claude.ai/api/organizations/org-1/usage",
       "builds the expected URL")
expect(session.currentCookies.contains { $0.name == "sessionKey" },
       "seeded cookie is present in the private jar")

// Cloudflare cookies must never survive into the jar.
let withCF = ClaudeSession(accountId: "check2", cookies: [
    cookie,
    HTTPCookie(properties: [.domain: ".claude.ai", .path: "/",
                            .name: "cf_clearance", .value: "x"])!,
])
expect(!withCF.currentCookies.contains { $0.name == "cf_clearance" },
       "Cloudflare cookies are filtered out of the jar")

// Two sessions must not share cookie state.
let other = ClaudeSession(accountId: "check3", cookies: [])
expect(other.currentCookies.isEmpty, "sessions are isolated from one another")

print(failures == 0 ? "\nALL SESSION CHECKS PASSED" : "\n\(failures) SESSION CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
```

Create `scripts/session_check.sh` (`chmod +x`):

```sh
#!/bin/bash
set -e
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)/session_check
swiftc -o "$OUT" \
    app/Core/CookiePolicy.swift \
    app/Core/CredentialStore.swift \
    app/Auth/ClaudeSession.swift \
    scripts/session_check/main.swift \
    -framework Foundation
"$OUT"
```

- [ ] **Step 2: Run the check to verify it fails**

Run: `./scripts/session_check.sh`
Expected: FAIL — `cannot find 'ClaudeSession' in scope`.

- [ ] **Step 3: Write the implementation**

Create `app/Auth/ClaudeSession.swift`:

```swift
import Foundation

public enum SessionError: Error {
    case unauthorized          // 401 / 403 — credentials rejected
    case http(Int)
    case transport(Error)
    case invalidResponse
}

/// One network session per account.
///
/// The critical property: cookies are NEVER written into a `Cookie` header by
/// hand. They are seeded into a private jar and attached by URLSession, which
/// means any `Set-Cookie` the server returns is captured instead of discarded.
/// That is the defect this type exists to fix.
public final class ClaudeSession {

    /// Shared by the native session and every WKWebView in the app, so cookies
    /// harvested in the browser stay valid natively.
    public static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.4.1 Safari/605.1.15"

    private static let baseURL = URL(string: "https://claude.ai")!

    public let accountId: String
    private let configuration: URLSessionConfiguration
    private let session: URLSession
    private var lastPersisted: [StoredCookie]

    /// Called on the main queue whenever the jar's contents actually change.
    public var onCookiesChanged: (([HTTPCookie]) -> Void)?

    public init(accountId: String, cookies: [HTTPCookie]) {
        self.accountId = accountId

        // .ephemeral gives this session a PRIVATE in-memory cookie jar, verified
        // not to leak into HTTPCookieStorage.shared or other sessions.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.httpAdditionalHeaders = [
            "User-Agent": ClaudeSession.userAgent,
            "Accept": "*/*",
            "Origin": "https://claude.ai",
            "Referer": "https://claude.ai/",
        ]

        for cookie in CookiePolicy.filter(cookies) {
            configuration.httpCookieStorage?.setCookie(cookie)
        }

        self.configuration = configuration
        self.session = URLSession(configuration: configuration)
        self.lastPersisted = CookiePolicy.filter(cookies).compactMap(StoredCookie.init)
    }

    public var currentCookies: [HTTPCookie] {
        CookiePolicy.filter(configuration.httpCookieStorage?.cookies(for: Self.baseURL) ?? [])
    }

    public var sessionKeyExpiry: Date? {
        CookiePolicy.sessionExpiry(in: currentCookies)
    }

    /// Exposed for verification: callers use `get(path:completion:)`.
    public func makeRequest(path: String) -> URLRequest {
        URLRequest(url: Self.baseURL.appendingPathComponent(path))
    }

    public func get(path: String, completion: @escaping (Result<Data, SessionError>) -> Void) {
        session.dataTask(with: makeRequest(path: path)) { [weak self] data, response, error in
            guard let self else { return }

            DispatchQueue.main.async {
                self.captureCookieRotation()

                if let error {
                    completion(.failure(.transport(error)))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    completion(.failure(.invalidResponse))
                    return
                }
                switch http.statusCode {
                case 200:
                    guard let data else { completion(.failure(.invalidResponse)); return }
                    completion(.success(data))
                case 401, 403:
                    completion(.failure(.unauthorized))
                default:
                    completion(.failure(.http(http.statusCode)))
                }
            }
        }.resume()
    }

    /// If the server rotated anything, persist it. As of the 2026-09-11 spike
    /// claude.ai does not rotate sessionKey on API calls, but capturing it is
    /// free and is the only way we would ever notice if that changed.
    private func captureCookieRotation() {
        let current = currentCookies.compactMap(StoredCookie.init)
        guard CookieDiff.changed(from: lastPersisted, to: current) else { return }
        NSLog("🔄 [\(accountId)] server rotated cookies: \(current.map(\.name).sorted())")
        lastPersisted = current
        onCookiesChanged?(currentCookies)
    }
}
```

- [ ] **Step 4: Run the check to verify it passes**

Run: `./scripts/session_check.sh`
Expected: `ALL SESSION CHECKS PASSED`, 6 PASS lines.

- [ ] **Step 5: Commit**

```bash
git add app/Auth/ClaudeSession.swift scripts/session_check/main.swift scripts/session_check.sh
git commit -m "feat: add per-account ClaudeSession with cookie rotation capture"
```

---

### Task 7: AccountStore

Owns account persistence, credential coordination, and one-shot migration. This is where the old `UserDefaults` cookie storage finally dies.

**Files:**
- Create: `app/Auth/AccountStore.swift`
- Modify: `app/ClaudeUsageBar.swift` — delete `struct Account` (lines 423-431) and the account-store section (lines 510-616)

**Interfaces:**
- Consumes: `Account`, `Migration`, `LegacyAccount`, `CredentialStore`, `KeychainStore`, `StoredCookie`, `SessionStateEvaluator` (Tasks 2-5)
- Produces: `AccountStore(credentials:defaults:)`; `.accounts: [Account]`; `.activeAccountId: String?`; `.activeAccount: Account?`; `cookies(for:) -> [HTTPCookie]`; `saveCookies(_:for:)`; `upsertAccount(_:cookies:) -> Account`; `removeAccount(_:)`; `setName(_:for:)`; `setActive(_:)`; `update(_:transform:)`; `state(for:) -> SessionState`

- [ ] **Step 1: Write the implementation**

Create `app/Auth/AccountStore.swift`:

```swift
import Foundation

/// Single source of truth for accounts and their credentials.
///
/// Accounts (no secrets) live in UserDefaults under `accounts_v3`.
/// Cookies live only in the credential store, keyed by account id.
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

    public init(credentials: CredentialStore = KeychainStore(),
                defaults: UserDefaults = .standard) {
        self.credentials = credentials
        self.defaults = defaults
        migrateIfNeeded()
        load()
    }

    // MARK: - Persistence

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

    // MARK: - Migration

    /// One-shot move of plaintext cookies out of UserDefaults and into the
    /// credential store. Deliberately removes the legacy single-cookie mirror,
    /// which means downgrading to an older build loses authentication.
    private func migrateIfNeeded() {
        guard !defaults.bool(forKey: migrationKey) else { return }

        var legacy: [LegacyAccount] = []
        if let data = defaults.data(forKey: legacyAccountsKey),
           let decoded = try? JSONDecoder().decode([LegacyAccount].self, from: data) {
            legacy = decoded
        } else if let solitary = defaults.string(forKey: legacyCookieKey), !solitary.isEmpty {
            // Pre-multi-account installs only ever had the single mirror key.
            legacy = [LegacyAccount(id: UUID().uuidString, name: "Account 1",
                                    cookie: solitary, sessionPercentage: nil)]
        }

        guard !legacy.isEmpty else {
            defaults.set(true, forKey: migrationKey)
            return
        }

        let result = Migration.migrate(legacy: legacy)
        for (accountId, cookies) in result.credentials where !cookies.isEmpty {
            try? credentials.save(cookies, for: accountId)
        }
        if let data = try? JSONEncoder().encode(result.accounts) {
            defaults.set(data, forKey: accountsKey)
        }

        defaults.removeObject(forKey: legacyAccountsKey)
        defaults.removeObject(forKey: legacyCookieKey)
        defaults.set(true, forKey: migrationKey)
        NSLog("✅ migrated \(result.accounts.count) account(s) to the keychain")
    }

    // MARK: - Credentials

    public func cookies(for accountId: String) -> [HTTPCookie] {
        ((try? credentials.load(for: accountId)) ?? []).compactMap(\.httpCookie)
    }

    public func saveCookies(_ cookies: [HTTPCookie], for accountId: String) {
        let stored = CookiePolicy.filter(cookies).compactMap(StoredCookie.init)
        try? credentials.save(stored, for: accountId)
        update(accountId) { $0.expiresAt = CookiePolicy.sessionExpiry(in: cookies) }
    }

    // MARK: - Accounts

    public var activeAccount: Account? {
        accounts.first { $0.id == activeAccountId }
    }

    /// Adds a new account or replaces an existing one's credentials.
    @discardableResult
    public func upsertAccount(_ account: Account, cookies: [HTTPCookie]) -> Account {
        var updated = account
        updated.expiresAt = CookiePolicy.sessionExpiry(in: cookies)
        updated.consecutiveAuthFailures = 0

        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = updated
        } else {
            accounts.append(updated)
        }
        activeAccountId = updated.id

        let stored = CookiePolicy.filter(cookies).compactMap(StoredCookie.init)
        try? credentials.save(stored, for: updated.id)
        persist()
        return updated
    }

    public func removeAccount(_ id: String) {
        accounts.removeAll { $0.id == id }
        try? credentials.delete(for: id)
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
            lastFetchFailedNonAuth: false
        )
    }
}
```

- [ ] **Step 2: Delete the superseded code from ClaudeUsageBar.swift**

Remove `struct Account` (lines 423-431 — now provided by `app/Core/Account.swift`) and the entire `// MARK: - Account store` section (lines 510-616), which includes `loadAccounts`, `persistAccounts`, `addAccount`, `updateActiveAccountCookie`, `switchAccount`, `setAccountName`, `removeAccount`, and `displayName`.

Keep `fetchAccountLabelIfNeeded` for now; Task 8 replaces it.

In `UsageManager`, replace the account properties with a store reference:

```swift
    let store = AccountStore()
    var accounts: [Account] { store.accounts }
    var activeAccountId: String? { store.activeAccountId }
    var activeAccount: Account? { store.activeAccount }
```

Because `accounts` is no longer `@Published`, add an explicit change notification wherever the store mutates:

```swift
    // Not private: the popover views call this after mutating the store.
    func accountsDidChange() {
        objectWillChange.send()
        updateStatusBar()
    }
```

Call `accountsDidChange()` after every `store.` mutation.

- [ ] **Step 3: Fix the remaining compile errors**

`sessionCookie` (line 493) no longer exists. Replace it with:

```swift
    private var activeCookies: [HTTPCookie] {
        guard let id = activeAccountId else { return [] }
        return store.cookies(for: id)
    }
```

Update `displayName(for:)` callers — reintroduce it on `UsageManager`:

```swift
    func displayName(for account: Account) -> String {
        let trimmed = account.name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Untitled account" : trimmed
    }
```

Leave the fetch methods referencing `activeCookies` broken for now if needed — Task 8 rewrites them. The build must compile by the end of this step, so temporarily adapt call sites with:

```swift
    private var legacyCookieHeader: String {
        activeCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
```

and point the existing `request.setValue(..., forHTTPHeaderField: "Cookie")` calls at it. This is scaffolding deleted in Task 8.

- [ ] **Step 4: Verify the build**

Run: `cd app && ./build.sh`
Expected: "Build successful!". Quit the launched app.

- [ ] **Step 5: Verify migration against a real plist**

Back up first, then inspect:

```bash
cp ~/Library/Preferences/com.claude.usagebar.plist /tmp/cub-backup.plist
defaults read com.claude.usagebar accounts_v2 2>/dev/null | head -5
```

Launch the app, quit it, then confirm the plaintext cookie is gone and the Keychain item exists:

```bash
defaults read com.claude.usagebar claude_session_cookie 2>&1 | grep -q "does not exist" && echo "✅ legacy mirror removed"
defaults read com.claude.usagebar accounts_v2 2>&1 | grep -q "does not exist" && echo "✅ legacy accounts removed"
security find-generic-password -s com.claude.usagebar.session >/dev/null 2>&1 && echo "✅ keychain item created"
```

Expected: all three ✅. If anything fails, restore with `cp /tmp/cub-backup.plist ~/Library/Preferences/com.claude.usagebar.plist` and re-run `defaults read` to debug.

- [ ] **Step 6: Commit**

```bash
git add app/Auth/AccountStore.swift app/ClaudeUsageBar.swift
git commit -m "feat: move account credentials into AccountStore and the keychain"
```

---

### Task 8: AccountLoginWindow

The embedded sign-in window. Contains the two landmines the spike found: popups must be honoured, and the popup window must not be double-released.

**Files:**
- Create: `app/UI/AccountLoginWindow.swift`

**Interfaces:**
- Consumes: `ClaudeSession.userAgent`, `CookiePolicy`, `Account`, `AccountStore` (Tasks 1, 3, 6, 7)
- Produces: `AccountLoginWindow.Mode` (`.newAccount`, `.reauth(accountId: String, expectedEmail: String?)`); `AccountLoginWindow.present(mode:onSuccess:onIdentityMismatch:)` where `onSuccess` is `(email: String, orgId: String?, cookies: [HTTPCookie]) -> Void` and `onIdentityMismatch` is `(_ signedInAs: String, _ expected: String) -> Void`

- [ ] **Step 1: Write the implementation**

Create `app/UI/AccountLoginWindow.swift`:

```swift
import AppKit
import WebKit

/// Hosts the real claude.ai login page in an isolated WebKit context.
///
/// Two non-obvious requirements, both established by spike on 2026-09-11:
///
///  1. claude.ai opens Google OAuth via `window.open`. Without a WKUIDelegate
///     that honours it, WebKit silently discards the popup and the Google
///     button appears to do nothing. There is no `disallowed_useragent` block —
///     the flow works once popups are handled.
///  2. `NSWindow(contentRect:...)` defaults `isReleasedWhenClosed = true`. When
///     the OAuth page calls `window.close()` while ARC also holds the window,
///     the process segfaults in `objc_release`. It MUST be set false.
final class AccountLoginWindow: NSObject, WKNavigationDelegate, WKUIDelegate {

    enum Mode {
        case newAccount
        case reauth(accountId: String, expectedEmail: String?)
    }

    private var window: NSWindow?
    private var webView: WKWebView!
    private var dataStore: WKWebsiteDataStore!
    private var popupWindows: [ObjectIdentifier: NSWindow] = [:]
    private var pollTimer: Timer?
    private var didComplete = false

    private let mode: Mode
    private let onSuccess: (String, String?, [HTTPCookie]) -> Void
    private let onIdentityMismatch: (String, String) -> Void

    /// Retains itself until the window closes; callers do not hold a reference.
    private static var live: AccountLoginWindow?

    static func present(mode: Mode,
                        onSuccess: @escaping (String, String?, [HTTPCookie]) -> Void,
                        onIdentityMismatch: @escaping (String, String) -> Void = { _, _ in }) {
        live = AccountLoginWindow(mode: mode, onSuccess: onSuccess,
                                  onIdentityMismatch: onIdentityMismatch)
        live?.show()
    }

    private init(mode: Mode,
                 onSuccess: @escaping (String, String?, [HTTPCookie]) -> Void,
                 onIdentityMismatch: @escaping (String, String) -> Void) {
        self.mode = mode
        self.onSuccess = onSuccess
        self.onIdentityMismatch = onIdentityMismatch
        super.init()
    }

    private func show() {
        // A non-persistent store starts every login from an empty cookie jar.
        // This is what lets a second account be added without a separate
        // browser or private window.
        dataStore = WKWebsiteDataStore.nonPersistent()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 760),
                            configuration: configuration)
        webView.customUserAgent = ClaudeSession.userAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self

        let window = NSWindow(contentRect: webView.frame,
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Sign in to Claude"
        window.contentView = webView
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.setActivationPolicy(.regular)   // menu-bar apps can't focus a window otherwise
        NSApp.activate(ignoringOtherApps: true)

        webView.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
        startPollingForSession()
    }

    // MARK: - Success detection

    /// Polls for `sessionKey`, then VERIFIES with a real API call before
    /// committing. Verification-based detection survives site redesigns that
    /// would break URL matching.
    private func startPollingForSession() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self, !self.didComplete else { timer.invalidate(); return }
            self.dataStore.httpCookieStore.getAllCookies { cookies in
                let claude = cookies.filter { $0.domain.contains("claude.ai") }
                guard claude.contains(where: { $0.name == "sessionKey" }) else { return }
                self.didComplete = true
                timer.invalidate()
                self.verify(cookies: CookiePolicy.filter(claude))
            }
        }
    }

    private func verify(cookies: [HTTPCookie]) {
        let session = ClaudeSession(accountId: "login-verify", cookies: cookies)
        session.get(path: "/api/bootstrap") { [weak self] result in
            guard let self else { return }
            guard case .success(let data) = result,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let account = json["account"] as? [String: Any] else {
                // Verification failed; let the user keep trying in the window.
                self.didComplete = false
                self.startPollingForSession()
                return
            }

            let email = (account["email_address"] as? String)
                ?? (account["full_name"] as? String) ?? "Claude account"
            // Org id comes from the cookie. NEVER from bootstrap — that key is gone.
            let orgId = cookies.first { $0.name == "lastActiveOrg" }?.value

            if case .reauth(_, let expected) = self.mode,
               let expected, !expected.isEmpty, expected != email {
                self.close()
                self.onIdentityMismatch(email, expected)
                return
            }

            self.close()
            self.onSuccess(email, orgId, cookies)
        }
    }

    private func close() {
        pollTimer?.invalidate()
        pollTimer = nil
        popupWindows.values.forEach { $0.close() }
        popupWindows.removeAll()
        window?.close()
        window = nil
        NSApp.setActivationPolicy(.accessory)   // back to menu-bar-only
        AccountLoginWindow.live = nil
    }

    // MARK: - WKUIDelegate

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // The supplied configuration carries the window.opener relationship the
        // OAuth callback posts back through — it must be reused, not replaced.
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640),
                              configuration: configuration)
        popup.customUserAgent = ClaudeSession.userAgent
        popup.navigationDelegate = self
        popup.uiDelegate = self

        let window = NSWindow(contentRect: popup.frame,
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false   // ← ARC owns it; AppKit must not release
        window.title = "Sign in"
        window.contentView = popup
        window.center()
        window.makeKeyAndOrderFront(nil)

        popupWindows[ObjectIdentifier(popup)] = window
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        let key = ObjectIdentifier(webView)
        popupWindows[key]?.close()
        popupWindows[key] = nil
    }
}
```

- [ ] **Step 2: Verify the build**

Run: `cd app && ./build.sh`
Expected: "Build successful!". Quit the launched app.

- [ ] **Step 3: Commit**

```bash
git add app/UI/AccountLoginWindow.swift
git commit -m "feat: add embedded claude.ai sign-in window with OAuth popup support"
```

---
### Task 9: Rewire all fetches through ClaudeSession

Deletes the last manual `Cookie` headers and the dead bootstrap fallback.

**Files:**
- Modify: `app/ClaudeUsageBar.swift` — `fetchOrganizationId` (756-795), `fetchUsage` (797-825), `fetchSessionPercentage*` (832-867), `fetchFreeCredits` (869-904), `fetchExtraUsage` (906-939), `fetchUsageWithOrgId` (941-998), `fetchAccountLabelIfNeeded` (625-650)

**Interfaces:**
- Consumes: `ClaudeSession`, `SessionError`, `AccountStore` (Tasks 6, 7)
- Produces: `UsageManager.session(for accountId: String) -> ClaudeSession`; `UsageManager.orgId(for account: Account) -> String?`; `UsageManager.handleAuthFailure(for accountId: String)`

- [ ] **Step 1: Add the session factory**

In `UsageManager`, add a cache so each account reuses one session (and therefore one cookie jar) across calls:

```swift
    private var sessions: [String: ClaudeSession] = [:]

    func session(for accountId: String) -> ClaudeSession {
        if let existing = sessions[accountId] { return existing }
        let session = ClaudeSession(accountId: accountId, cookies: store.cookies(for: accountId))
        session.onCookiesChanged = { [weak self] cookies in
            self?.store.saveCookies(cookies, for: accountId)
        }
        sessions[accountId] = session
        return session
    }

    /// Call after credentials change so the next fetch uses a fresh jar.
    func invalidateSession(for accountId: String) {
        sessions.removeValue(forKey: accountId)
    }
```

- [ ] **Step 2: Replace fetchOrganizationId with a cookie read**

Delete `fetchOrganizationId` entirely (lines 756-795) — the bootstrap half of it reads `account["lastActiveOrgId"]`, a key claude.ai no longer returns, so it never succeeded. Replace with:

```swift
    /// Org id comes from the `lastActiveOrg` cookie. The old /api/bootstrap
    /// fallback read a key that no longer exists and was dead code.
    func orgId(for account: Account) -> String? {
        if let cached = account.orgId, !cached.isEmpty { return cached }
        let fromCookie = store.cookies(for: account.id)
            .first { $0.name == "lastActiveOrg" }?.value
        if let fromCookie {
            store.update(account.id) { $0.orgId = fromCookie }
        }
        return fromCookie
    }
```

- [ ] **Step 3: Rewrite fetchUsage**

```swift
    func fetchUsage() {
        guard let account = activeAccount else {
            errorMessage = "No account configured"
            return
        }
        guard let org = orgId(for: account) else {
            errorMessage = "Sign in again to finish setting up this account"
            return
        }

        isLoading = true
        errorMessage = nil

        session(for: account.id).get(path: "/api/organizations/\(org)/usage") { [weak self] result in
            guard let self else { return }
            self.isLoading = false

            switch result {
            case .success(let data):
                self.store.update(account.id) {
                    $0.consecutiveAuthFailures = 0
                    $0.lastSuccessfulFetch = Date()
                }
                self.parseUsageData(data)
                self.fetchFreeCredits(org)
                self.fetchExtraUsage(org)
                self.refreshInactiveAccountSessionPercentages()
            case .failure(.unauthorized):
                self.handleAuthFailure(for: account.id)
            case .failure(.transport), .failure(.invalidResponse):
                self.errorMessage = "Network error"
            case .failure(.http(let code)):
                self.errorMessage = "HTTP \(code)"
            }
            self.updateStatusBar()
        }
    }
```

- [ ] **Step 4: Add the auth-failure ladder**

```swift
    /// Two consecutive rejections before demanding a re-login, so one bad
    /// response never sends the user through sign-in unnecessarily.
    /// Stored credentials are NEVER deleted here.
    func handleAuthFailure(for accountId: String) {
        store.update(accountId) { $0.consecutiveAuthFailures += 1 }
        guard let account = accounts.first(where: { $0.id == accountId }) else { return }

        // A single rejection is not yet grounds for demanding re-login.
        // Task 10 adds a renewal attempt here.
        guard account.consecutiveAuthFailures >= 2 else { return }

        errorMessage = nil   // the per-account banner replaces the raw string
        accountsDidChange()
    }
```

- [ ] **Step 5: Rewrite the remaining fetches**

Replace `fetchSessionPercentage(for:)` and `fetchSessionPercentageWithOrgId` with one method:

```swift
    func fetchSessionPercentage(for account: Account) {
        guard let org = orgId(for: account) else { return }
        session(for: account.id).get(path: "/api/organizations/\(org)/usage") { [weak self] result in
            guard let self, case .success(let data) = result,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let fiveHour = json["five_hour"] as? [String: Any],
                  let utilization = fiveHour["utilization"] as? Double else { return }
            self.store.update(account.id) {
                $0.sessionPercentage = Int(utilization)
                $0.lastSuccessfulFetch = Date()
            }
            self.accountsDidChange()
        }
    }
```

Rewrite `fetchFreeCredits` and `fetchExtraUsage` the same way — keep their existing JSON parsing bodies verbatim, and replace only the request construction:

```swift
    func fetchFreeCredits(_ orgId: String) {
        guard let accountId = activeAccountId else { return }
        session(for: accountId).get(path: "/api/organizations/\(orgId)/prepaid/credits") { [weak self] result in
            guard let self, case .success(let data) = result else { return }
            // ... existing parsing body from lines 884-903, unchanged ...
        }
    }

    func fetchExtraUsage(_ orgId: String) {
        guard let accountId = activeAccountId else { return }
        session(for: accountId).get(path: "/api/organizations/\(orgId)/overage_spend_limit") { [weak self] result in
            guard let self, case .success(let data) = result else { return }
            // ... existing parsing body from lines 921-938, unchanged ...
        }
    }
```

Delete `fetchUsageWithOrgId` (941-998) and `fetchAccountLabelIfNeeded` (625-650) — Task 8's login flow supplies the email directly.

- [ ] **Step 6: Verify no manual Cookie headers remain**

Run:

```bash
grep -n 'forHTTPHeaderField: "Cookie"' app/ClaudeUsageBar.swift
grep -rn 'lastActiveOrgId' app/
```

Expected: **no output from either.** Any hit is a violation of the global constraints.

- [ ] **Step 7: Verify the build and a live fetch**

Run: `cd app && ./build.sh`
Expected: "Build successful!", app launches, menu bar shows a real percentage for the migrated account.

- [ ] **Step 8: Commit**

```bash
git add app/ClaudeUsageBar.swift
git commit -m "refactor: route all claude.ai fetches through ClaudeSession"
```

---

### Task 10: SessionRenewal

The near-expiry renewal attempt. Expected to no-op today; retained because it is the only mechanism that would capture a server-side sliding refresh if one exists.

**Files:**
- Create: `app/Auth/SessionRenewal.swift`

**Interfaces:**
- Consumes: `ClaudeSession.userAgent`, `CookiePolicy` (Tasks 1, 6)
- Produces: `SessionRenewal.attempt(accountId:cookies:completion:)` where `completion` is `([HTTPCookie]?) -> Void`, called on the main queue with `nil` when nothing changed

- [ ] **Step 1: Write the implementation**

Create `app/Auth/SessionRenewal.swift`:

```swift
import AppKit
import WebKit

/// Replays stored cookies into a throwaway browser context, loads claude.ai,
/// and harvests whatever comes back.
///
/// As of the 2026-09-11 spike this does NOT renew anything: sessionKey is a
/// fixed-term 28-day token that neither rotates on API calls nor refreshes on
/// page load. It is kept because the spike ran 28 days from expiry, and a
/// server-side sliding refresh — if one exists — would only fire near expiry.
/// It costs nothing when it no-ops.
enum SessionRenewal {

    private static var inFlight: [String: RenewalTask] = [:]

    static func attempt(accountId: String,
                        cookies: [HTTPCookie],
                        completion: @escaping ([HTTPCookie]?) -> Void) {
        guard inFlight[accountId] == nil, !cookies.isEmpty else {
            completion(nil)
            return
        }
        let task = RenewalTask(accountId: accountId, cookies: cookies) { renewed in
            inFlight[accountId] = nil
            completion(renewed)
        }
        inFlight[accountId] = task
        task.start()
    }

    private final class RenewalTask {
        private let accountId: String
        private let original: [HTTPCookie]
        private let completion: ([HTTPCookie]?) -> Void
        private var webView: WKWebView?
        private var dataStore: WKWebsiteDataStore?

        init(accountId: String, cookies: [HTTPCookie],
             completion: @escaping ([HTTPCookie]?) -> Void) {
            self.accountId = accountId
            self.original = cookies
            self.completion = completion
        }

        func start() {
            let dataStore = WKWebsiteDataStore.nonPersistent()
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = dataStore

            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1, height: 1),
                                    configuration: configuration)
            webView.customUserAgent = ClaudeSession.userAgent
            self.webView = webView
            self.dataStore = dataStore

            let group = DispatchGroup()
            for cookie in original {
                group.enter()
                dataStore.httpCookieStore.setCookie(cookie) { group.leave() }
            }

            group.notify(queue: .main) {
                webView.load(URLRequest(url: URL(string: "https://claude.ai/")!))
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) { self.harvest() }
            }
        }

        private func harvest() {
            guard let dataStore else { finish(nil); return }
            dataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self else { return }
                let harvested = CookiePolicy.filter(cookies.filter { $0.domain.contains("claude.ai") })

                let oldKey = self.original.first { $0.name == "sessionKey" }
                let newKey = harvested.first { $0.name == "sessionKey" }
                guard let newKey else { self.finish(nil); return }

                let valueChanged = newKey.value != oldKey?.value
                let expiryExtended = (newKey.expiresDate ?? .distantPast)
                    > (oldKey?.expiresDate ?? .distantPast)

                if valueChanged || expiryExtended {
                    NSLog("✅ [\(self.accountId)] silent renewal extended the session")
                    self.finish(harvested)
                } else {
                    self.finish(nil)
                }
            }
        }

        private func finish(_ result: [HTTPCookie]?) {
            webView?.stopLoading()
            webView = nil
            dataStore = nil
            DispatchQueue.main.async { self.completion(result) }
        }
    }
}
```

- [ ] **Step 2: Wire renewal into the auth-failure ladder**

Task 9 deferred this. In `UsageManager.handleAuthFailure(for:)`, replace the
`guard account.consecutiveAuthFailures >= 2 else { return }` line with:

```swift
        // One rejection: try a silent renewal before troubling the user.
        if account.consecutiveAuthFailures == 1 {
            store.update(accountId) { $0.lastRenewalAttempt = Date() }
            SessionRenewal.attempt(accountId: accountId,
                                   cookies: store.cookies(for: accountId)) { [weak self] renewed in
                guard let self, let renewed else { return }
                self.store.saveCookies(renewed, for: accountId)
                self.invalidateSession(for: accountId)
                self.fetchUsage()
            }
            return
        }
        guard account.consecutiveAuthFailures >= 2 else { return }
```

- [ ] **Step 3: Verify the build**

Run: `cd app && ./build.sh`
Expected: "Build successful!". Quit the app.

- [ ] **Step 4: Commit**

```bash
git add app/Auth/SessionRenewal.swift app/ClaudeUsageBar.swift
git commit -m "feat: add near-expiry silent session renewal"
```

---

### Task 11: Proactive expiry scheduling and notifications

Wires the derived state into the existing 300s refresh timer.

**Files:**
- Modify: `app/ClaudeUsageBar.swift` — `UsageManager` (add the sweep), `loadSettings`/`saveSettings` (694-737), `sendNotification` region (1157-1183)

**Interfaces:**
- Consumes: `SessionStateEvaluator`, `SessionRenewal`, `AccountStore` (Tasks 2, 7, 10)
- Produces: `UsageManager.sweepSessionHealth()`; `UsageManager.sessionNotificationsEnabled: Bool`; `UsageManager.state(for: Account) -> SessionState`

- [ ] **Step 1: Add the settings toggle**

In `UsageManager`, alongside the other `@Published` settings:

```swift
    @Published var sessionNotificationsEnabled: Bool = true
```

In `loadSettings()`:

```swift
        sessionNotificationsEnabled =
            defaults.object(forKey: "session_notifications") as? Bool ?? true
```

In `saveSettings()`:

```swift
        defaults.set(sessionNotificationsEnabled, forKey: "session_notifications")
```

- [ ] **Step 2: Add the health sweep**

```swift
    func state(for account: Account) -> SessionState {
        SessionStateEvaluator.evaluate(
            expiresAt: account.expiresAt,
            consecutiveAuthFailures: account.consecutiveAuthFailures,
            lastFetchFailedNonAuth: false
        )
    }

    /// Runs on every refresh cycle. Attempts renewal inside the 7-day window,
    /// and warns once a day from 3 days out — before anything breaks.
    func sweepSessionHealth() {
        for account in accounts {
            if SessionStateEvaluator.shouldAttemptRenewal(
                expiresAt: account.expiresAt,
                lastRenewalAttempt: account.lastRenewalAttempt) {

                store.update(account.id) { $0.lastRenewalAttempt = Date() }
                SessionRenewal.attempt(accountId: account.id,
                                       cookies: store.cookies(for: account.id)) { [weak self] renewed in
                    guard let self, let renewed else { return }
                    self.store.saveCookies(renewed, for: account.id)
                    self.invalidateSession(for: account.id)
                    self.accountsDidChange()
                }
            }

            if case .expiringSoon(let days) = state(for: account) {
                notifyExpiringSoon(account: account, daysRemaining: days)
            }
        }
    }

    private func notifyExpiringSoon(account: Account, daysRemaining: Int) {
        guard sessionNotificationsEnabled else { return }

        // At most one notice per account per calendar day.
        let key = "expiry_notified_\(account.id)"
        let today = Calendar.current.startOfDay(for: Date())
        if let last = UserDefaults.standard.object(forKey: key) as? Date,
           Calendar.current.startOfDay(for: last) == today { return }
        UserDefaults.standard.set(Date(), forKey: key)

        let notification = NSUserNotification()
        notification.title = "Claude sign-in expiring"
        notification.informativeText = daysRemaining <= 0
            ? "\(displayName(for: account)) expires today. Sign in again to keep tracking usage."
            : "\(displayName(for: account)) expires in \(daysRemaining) day\(daysRemaining == 1 ? "" : "s")."
        NSUserNotificationCenter.default.deliver(notification)
    }
```

Note: this matches the existing app's use of `NSUserNotification` (see `sendNotification` at line 1157) rather than introducing `UNUserNotificationCenter`, which would require new entitlements.

- [ ] **Step 3: Call the sweep from the refresh timer**

In `AppDelegate.applicationDidFinishLaunching`, extend the existing 300s timer at line 106:

```swift
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            self.usageManager.fetchUsage()
            self.usageManager.sweepSessionHealth()
        }
```

Also call `usageManager.sweepSessionHealth()` once directly after the initial fetch during launch.

- [ ] **Step 4: Verify the scheduling logic without waiting days**

Temporarily force an expiry to confirm the ladder fires. Add this to `applicationDidFinishLaunching`, run, observe, then remove it:

```swift
        // TEMPORARY verification — delete before committing.
        if let id = usageManager.activeAccountId {
            usageManager.store.update(id) { $0.expiresAt = Date().addingTimeInterval(2 * 86_400) }
            usageManager.sweepSessionHealth()
        }
```

Run: `cd app && ./build.sh`
Expected: a notification reading "expires in 2 days", and Console shows a renewal attempt. **Remove the temporary block and rebuild before committing.**

- [ ] **Step 5: Commit**

```bash
git add app/ClaudeUsageBar.swift
git commit -m "feat: warn before session expiry and attempt renewal near the window"
```

---

### Task 12: Sign-in UI and end-to-end verification

Replaces the DevTools instructions with a button, demotes pasting to an advanced disclosure, and adds per-account state.

**Files:**
- Modify: `app/ClaudeUsageBar.swift` — error banner (1892-1906), `accountsPanel` (2484-2535), `addAccountForm` (2540-2640), `beginReauthentication` (2641-2647), `accountSwitcher` (2448-2481)

**Interfaces:**
- Consumes: `AccountLoginWindow`, `SessionState`, `AccountStore` (Tasks 2, 7, 8)
- Produces: user-facing sign-in flow; no new code interfaces

- [ ] **Step 1: Add the sign-in entry point**

In the popover view, add:

```swift
    @State private var showingAdvancedPaste = false

    private func presentLogin(mode: AccountLoginWindow.Mode) {
        AccountLoginWindow.present(mode: mode, onSuccess: { email, orgId, cookies in
            let existingId: String? = {
                if case .reauth(let id, _) = mode { return id }
                return nil
            }()
            let account = Account(
                id: existingId ?? UUID().uuidString,
                name: usageManager.accounts.first { $0.id == existingId }?.name ?? email,
                email: email,
                orgId: orgId
            )
            usageManager.store.upsertAccount(account, cookies: cookies)
            usageManager.invalidateSession(for: account.id)
            usageManager.accountsDidChange()
            usageManager.fetchUsage()
        }, onIdentityMismatch: { signedInAs, expected in
            usageManager.errorMessage =
                "Signed in as \(signedInAs), but this account is \(expected). Use “Add account” instead."
        })
    }
```

- [ ] **Step 2: Replace the setup screen**

Replace the body of `addAccountForm` (2540-2640). The six-step DevTools list and paste field move behind a disclosure; the primary action becomes a button:

```swift
    var addAccountForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { presentLogin(mode: .newAccount) }) {
                Label("Sign in with Claude", systemImage: "person.crop.circle.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

            Text("Opens the Claude login page. Works with Google and email sign-in.")
                .font(.caption2)
                .foregroundColor(Color.secondaryText)

            DisclosureGroup("Paste cookie manually (advanced)", isExpanded: $showingAdvancedPaste) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. Go to Settings > Usage on claude.ai")
                    Text("2. Press F12 (or Cmd+Option+I)")
                    Text("3. Go to Network tab")
                    Text("4. Refresh page, click 'usage' request")
                    Text("5. Find 'Cookie' in Request Headers")
                    Text("6. Copy the full cookie value")
                }
                .font(.caption2)
                .foregroundColor(Color.secondaryText)

                PasteableTextField(text: $sessionCookieInput, placeholder: "Paste cookie here...")
                    .frame(height: 50)
                    .cornerRadius(4)

                Button("Save Cookie & Fetch") {
                    let pasted = sessionCookieInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !pasted.isEmpty else {
                        usageManager.errorMessage = "Cookie field is empty!"
                        return
                    }
                    let cookies = CookiePolicy.parse(pasted: pasted)
                    guard cookies.contains(where: { $0.name == "sessionKey" }) else {
                        usageManager.errorMessage = "That cookie has no sessionKey in it."
                        return
                    }
                    usageManager.store.upsertAccount(
                        Account(name: newAccountName.isEmpty ? "Account" : newAccountName),
                        cookies: cookies)
                    sessionCookieInput = ""
                    newAccountName = ""
                    showingAddAccount = false
                    usageManager.accountsDidChange()
                    usageManager.fetchUsage()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .font(.caption2)
        }
    }
```

**Delete** the "sign in to each account in a separate browser or private window" tip at line 2577 — isolated data stores make it false.

- [ ] **Step 3: Show per-account state in the accounts list**

Inside `accountsPanel`'s `ForEach` (line 2492), after the name `TextField`, add:

```swift
                        switch usageManager.state(for: acct) {
                        case .healthy:
                            EmptyView()
                        case .expiringSoon(let days):
                            Text(days <= 0 ? "expires today" : "\(days)d")
                                .font(.caption2)
                                .foregroundColor(.orange)
                                .help("Sign-in expires soon")
                        case .needsSignIn:
                            Button("Sign in") {
                                presentLogin(mode: .reauth(accountId: acct.id,
                                                           expectedEmail: acct.email))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                        case .temporarilyUnavailable:
                            Image(systemName: "wifi.exclamationmark")
                                .foregroundColor(Color.secondaryText)
                                .help("Temporarily unreachable")
                        }
```

- [ ] **Step 4: Replace the HTTP 403 banner**

Replace the `error == "HTTP 403"` block (1898-1904) with state-driven copy:

```swift
            if let account = usageManager.activeAccount,
               usageManager.state(for: account) == .needsSignIn {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your Claude sign-in for \(usageManager.displayName(for: account)) has expired.")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Button(action: {
                        presentLogin(mode: .reauth(accountId: account.id,
                                                   expectedEmail: account.email))
                    }) {
                        Label("Sign in again", systemImage: "person.crop.circle.badge.checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.bottom, 8)
            }
```

Update `accountSwitcher`'s "Add Account…" item (2462) to call `presentLogin(mode: .newAccount)`, and delete `beginReauthentication` (2641-2647).

- [ ] **Step 5: Add the menu bar indicator**

Spec §7 requires a subtle marker when any account needs attention. In
`UsageManager.statusBarTitle()` (line 476), append a trailing `!` when any
account is in `.needsSignIn`:

```swift
    func statusBarTitle() -> String {
        guard !accounts.isEmpty else { return "No accounts" }

        let body = accounts.enumerated().map { index, account in
            let percentageText = account.sessionPercentage.map { "\($0)%" } ?? "--"
            return "\(index + 1): \(percentageText)"
        }.joined(separator: "  ")

        let needsAttention = accounts.contains { state(for: $0) == .needsSignIn }
        return needsAttention ? body + " !" : body
    }
```

- [ ] **Step 6: Verify the build**

Run: `cd app && ./build.sh`
Expected: "Build successful!".

- [ ] **Step 7: Run the full manual checklist**

Each item is a pass/fail gate. Record results.

1. **Fresh sign-in.** Remove all accounts, click "Sign in with Claude", complete Google sign-in. → Account appears named by email; usage renders.
2. **Popup crash guard.** During step 1, let the Google popup close itself. → **No crash.** (This is the `isReleasedWhenClosed` regression from spike §2.8.)
3. **Second account, no browser tricks.** Add a second, different account without opening any private window. → Both appear; both show independent percentages; neither logs the other out.
4. **Persistence.** Quit and relaunch. → Both accounts still work with no re-login.
5. **Migration.** Restore `/tmp/cub-backup.plist`, launch an older-format install, let it migrate. → Accounts survive; `defaults read com.claude.usagebar claude_session_cookie` reports "does not exist"; `security find-generic-password -s com.claude.usagebar.session` finds an item.
6. **Isolated failure.** Corrupt one account's stored credential:
   ```bash
   security delete-generic-password -s com.claude.usagebar.session -a "<account-uuid>"
   ```
   Refresh twice. → That account shows "Sign in"; the other keeps updating; clicking "Sign in" restores it.
7. **Identity guard.** On an existing account, click "Sign in", then sign into a *different* Claude account. → The mismatch message appears and the original account is not repointed.
8. **Removal.** Delete an account, then run `security find-generic-password -s com.claude.usagebar.session -a "<uuid>"`. → Not found.
9. **No manual cookie headers.** `grep -rn 'forHTTPHeaderField: "Cookie"' app/` → no output.

- [ ] **Step 8: Update the README setup instructions**

`README.md` lines 19-25 and `app/README.md` describe the DevTools flow as the only setup path. Replace with:

```markdown
## 📦 Set Up (10 seconds)

1. Launch ClaudeUsageBar
2. Click **Sign in with Claude**
3. Sign in normally — Google or email both work

Your session is stored in the macOS Keychain. Add more accounts the same way;
each is kept separate, so there's no need for separate browsers.
```

Delete the `setup-guide.png` reference, and note in the release section that upgrading migrates existing cookies automatically and that downgrading requires signing in again.

- [ ] **Step 9: Commit**

```bash
git add app/ClaudeUsageBar.swift README.md app/README.md
git commit -m "feat: replace DevTools cookie setup with one-click sign-in"
```

---

## Done

All twelve tasks complete means: sign-in is a button, accounts are isolated, credentials are in the Keychain, sessions capture rotation, and expiry is announced three days ahead instead of arriving as an unexplained `HTTP 403`.

Two questions from spec §10 remain open by design and need no code:

1. **Does claude.ai slide `sessionKey` near expiry?** `ClaudeSession.captureCookieRotation` and `SessionRenewal` both log when they observe a change. Check Console for `🔄` or `✅ silent renewal` around late October 2026. If it does renew, users stop re-authenticating entirely with no further work.
2. **Is the allowlist minimal?** `routingHint`, `anthropic-device-id`, and `sessionKeyLC` are carried on the assumption they may matter. Removing them one at a time and confirming `/usage` still returns 200 would narrow it.
