# Account Sign-In & Session Management — Design

**Date:** 2026-09-11
**Status:** Approved for planning
**Scope:** How ClaudeUsageBar authenticates to claude.ai, stores credentials, and handles session expiry across multiple accounts.

## 1. Problem

Two distinct problems, often confused with each other.

**Signing in is hard.** The only way to add an account is to open DevTools on claude.ai, find the Network tab, locate the `usage` request, and copy its raw `Cookie` header — six steps, documented in-app at `ClaudeUsageBar.swift:2568-2573`. Adding a *second* account additionally requires a separate browser or private window (`:2577`), because claude.ai's cookies overwrite each other within one browser profile.

**Sessions break silently.** The pasted cookie is a frozen snapshot. Every fetch sets the header by hand:

```swift
request.setValue(sessionCookie, forHTTPHeaderField: "Cookie")   // :960, :844, :878, :915, :632
```

Because the cookie is written but never read back from responses, the stored value can only decay. When it dies, the menu bar shows `HTTP 403` with no explanation, and the user repeats the six steps.

### Supporting defects found while investigating

- **Dead fallback.** `fetchOrganizationId` falls back to reading `account["lastActiveOrgId"]` from `/api/bootstrap` (`:791`). That key no longer exists in the response. Any user whose cookie lacks `lastActiveOrg` hits "Could not get org ID from cookie" with no recovery path.
- **Shared cookie jar.** All accounts use `URLSession.shared`, whose cookie storage is process-global.
- **Credentials in plaintext.** Cookies live in `UserDefaults` (`:540-548`), i.e. `~/Library/Preferences/com.claude.usagebar.plist`, readable by any process running as the user, and mirrored to a second legacy key.
- **Self-inflicted 403s.** The app sends a hardcoded Chrome 120 User-Agent (`:961`) alongside cookies harvested from the user's real browser, including Cloudflare's `cf_clearance`, which is bound to UA and IP. See §2, finding 4.
- **Only 403 is recoverable.** `:1898` offers a Re-authenticate button for `HTTP 403` exactly; 401 and everything else is a dead end.

## 2. Spike findings (2026-09-11)

A throwaway WKWebView harness was built and driven against a real account. These results are evidence, not assumptions, and they changed the design.

1. **Ephemeral cookie jars are isolated.** A cookie set in one `URLSessionConfiguration.ephemeral` is invisible to another and to `HTTPCookieStorage.shared`. Per-account sessions are sound.
2. **Google sign-in works inside WKWebView.** The full OAuth flow completed (identifier → CheckCookie → SetSID → consent → `gsi/transform`). It initially appeared broken only because the harness lacked a `WKUIDelegate`; claude.ai opens Google OAuth via `window.open`, and WebKit silently discards popups when unhandled. There is **no** `disallowed_useragent` block.
3. **Native calls work with no manual `Cookie` header.** With cookies seeded into a private jar, `GET /api/organizations/{org}/usage` returned HTTP 200.
4. **Cloudflare cookies are not required.** The same call returned 200 with `cf_clearance`, `__cf_bm`, and `_cfuvid` removed. This is the root fix for the mystery 403s: rather than matching a UA to satisfy `cf_clearance`, the app should never store or send Cloudflare cookies at all.
5. **`sessionKey` is a fixed-term, non-sliding 28-day token.** Issued 2026-09-11, expires 2026-10-09. It did **not** rotate across API calls, and it did **not** renew when a real browser context loaded `https://claude.ai/` with it injected — identical value fingerprint and identical expiry both times.
6. **Org ID comes from the `lastActiveOrg` cookie**, confirming the bootstrap fallback is dead code.
7. **Login can be detected by polling** the WebKit cookie store for `sessionKey`.
8. **Popup `NSWindow` over-releases.** `NSWindow(contentRect:styleMask:backing:defer:)` defaults `isReleasedWhenClosed = true`. When the OAuth page calls `window.close()` while ARC also holds the window, the process segfaults (`EXC_BAD_ACCESS` in `objc_release` ← `-[_NSWindowTransformAnimation dealloc]`, confirmed in the crash report).

### Consequence: the goal must be restated

Finding 5 means **"never re-authenticate" is not achievable.** The server issues a fixed 28-day credential and does not extend it on use. No client-side mechanism can outlive a token the server will not reissue.

Caveat, deliberately left open: the renewal test ran 28 days *before* expiry. Systems commonly refresh only within a window near expiry. If claude.ai does that, §6 picks it up automatically. The design does not depend on it.

The honest objective:

| | Today | After |
|---|---|---|
| Add an account | 6 DevTools steps | 2 clicks (Google) or an email code |
| Second account | Separate browser or private window | Works directly, fully isolated |
| Re-auth interval | ~28 days, silent breakage | ~28 days, warned 3 days ahead |
| Unexplained 403s | Common | Eliminated |
| Credentials at rest | Plaintext plist | Keychain |

## 3. Goals / Non-goals

**Goals**
- One-click sign-in via the real claude.ai login page, including Google.
- Multiple accounts without browser gymnastics.
- Credentials in the Keychain.
- Expiry known in advance and surfaced before breakage; re-auth is two clicks.
- Per-account failure isolation — one dead account never blocks the others.
- Eliminate the Cloudflare/UA-mismatch 403 class.

**Non-goals**
- Anthropic API keys. They do not report claude.ai subscription usage.
- Storing passwords, or automating login without the user present.
- Changes to usage parsing, thresholds, status page, or update banner.

## 4. Data model

```swift
enum SessionState: Equatable {
    case healthy
    case expiringSoon(daysRemaining: Int)   // <= 3 days
    case needsSignIn                        // expired, or auth rejected twice
    case temporarilyUnavailable             // network / 5xx — do not alarm
}

struct Account: Identifiable, Codable, Equatable {
    let id: String                  // stable UUID; keys Keychain item + thresholds
    var name: String                // user label, auto-filled from email
    var email: String?              // identity check on re-login
    var orgId: String?              // from the lastActiveOrg cookie
    var sessionPercentage: Int?
    var expiresAt: Date?            // sessionKey expiry — drives proactive UX
    var lastSuccessfulFetch: Date?
    var lastRenewalAttempt: Date?
    var consecutiveAuthFailures: Int
}
```

`Account` carries **no secrets** and stays in `UserDefaults`. Cookies live only in the Keychain, keyed by `id`. `SessionState` is derived, not stored — see §6.

## 5. Components

### 5.1 `CookiePolicy` — what is kept and sent

An allowlist, not a blocklist.

**Persisted and sent:** `sessionKey`, `sessionKeyLC`, `lastActiveOrg`, `routingHint`, `anthropic-device-id`.

**Never persisted or sent:**
- Cloudflare: `cf_clearance`, `__cf_bm`, `_cfuvid` — proven unnecessary (§2.4) and the cause of UA-mismatch 403s.
- Analytics: `_fbp`, `ajs_anonymous_id`, `_dd_s_v2`, `__ssid`, `g_state`, `_ga*`.
- UI state: `CH-prefers-color-scheme`, `user-sidebar-visible-on-load`, `activitySessionId`, `ion-vk`.

Also owns: parsing a legacy pasted `name=value; …` string, and extracting `sessionKey`'s expiry.

During implementation, narrow the allowlist further if `sessionKey` + `lastActiveOrg` alone suffice; §2.4 already proved the Cloudflare entries are not load-bearing.

### 5.2 `KeychainStore`

`kSecClassGenericPassword`, service `com.claude.usagebar.session`, account = the `Account.id`, accessibility `kSecAttrAccessibleWhenUnlocked`. Value is JSON of a minimal `StoredCookie` array (`name`, `value`, `domain`, `path`, `expiresAt`, `isSecure`, `isHTTPOnly`), rebuilt into `HTTPCookie` on load. Deleting an account deletes its item.

### 5.3 `ClaudeSession` — one per account

```swift
final class ClaudeSession {
    init(accountId: String, cookies: [HTTPCookie])
    func get(_ path: String) async throws -> (Data, HTTPURLResponse)
    var currentCookies: [HTTPCookie] { get }
    var sessionKeyExpiry: Date? { get }
}
```

Rules, all of which are the point of this component:

- Built on `URLSessionConfiguration.ephemeral` — private cookie jar, verified isolated (§2.1).
- **Never sets the `Cookie` header manually.** `httpShouldSetCookies = true`, `httpCookieAcceptPolicy = .always`; URLSession attaches cookies and captures `Set-Cookie`.
- One UA constant shared by the session *and* the login webview, so anything harvested in the browser stays valid natively.
- After each response, diff the jar against what was persisted; on change, write through to the Keychain **and log the observation** (this feeds the open question in §10).

### 5.4 `AccountLoginWindow`

A 520×760 `NSWindow` hosting a `WKWebView` on `https://claude.ai/login`, in two modes: `.newAccount` and `.reauth(accountId)`.

- `websiteDataStore = .nonPersistent()` — every login starts from an empty jar. **This is what removes the "use a separate browser" requirement.**
- `customUserAgent` = the shared UA constant.
- Implements `WKUIDelegate`:
  - `createWebViewWith:` must **reuse the supplied `WKWebViewConfiguration`**, which carries the `window.opener` relationship the OAuth callback posts back through. Present it in a child window with the same UA and delegates. Without this, Google sign-in silently does nothing (§2.2).
  - The child window **must** set `isReleasedWhenClosed = false`, or `webViewDidClose` segfaults the app (§2.8).
- Success detection: poll `httpCookieStore` every 2s for `sessionKey`; on appearance, harvest, then **verify** with a real `/api/bootstrap` call before committing anything. Verification-based, so a site redesign cannot silently break it.
- Identity: email from bootstrap `account.email_address`; org from the `lastActiveOrg` cookie, never from bootstrap (§2.6).
- **Re-login identity guard:** in `.reauth` mode, if the harvested email differs from the account's stored email, do not silently repoint the slot. Tell the user which account they actually signed into and offer to add it as a new one.

### 5.5 `SessionRenewal`

`attemptSilentRenewal(accountId)`: create a fresh non-persistent data store, inject stored cookies, load `https://claude.ai/` in an offscreen `WKWebView`, wait ~12s, harvest, and persist only if `sessionKey`'s value or expiry actually changed. Always tear down the webview and data store afterwards. Rate-limited to once per account per 24h.

Per §2.5 this is not expected to succeed today. It is retained because it is cheap, it is the only mechanism that would capture a near-expiry sliding refresh if one exists, and it costs nothing when it no-ops.

## 6. Expiry and failure handling

`SessionState` is derived on each refresh cycle from `expiresAt`, `lastSuccessfulFetch`, and `consecutiveAuthFailures` — a pure function, and the main unit-test target.

**Proactive ladder,** run on the existing 300s timer:

| Condition | Action |
|---|---|
| expiry > 7 days | `.healthy` |
| expiry ≤ 7 days, no attempt in 24h | `attemptSilentRenewal` |
| expiry ≤ 3 days | `.expiringSoon`, banner + at most one notification per day |
| expired | `.needsSignIn` |

**Reactive ladder,** on a failed fetch:

- **401/403:** (1) if any Cloudflare cookie is somehow present, strip and retry once — defensive, should be unreachable given §5.1; (2) `attemptSilentRenewal` if not rate-limited, then retry once; (3) increment `consecutiveAuthFailures`, and at 2 mark `.needsSignIn` with a one-click re-login on that row.
- **5xx / network:** `.temporarilyUnavailable`. Keep the last known percentage, show nothing alarming, retry next cycle.

**Stored cookies are never deleted on failure.** Only an explicit account removal, or a successful re-login, replaces them. A Claude outage must not destroy working credentials.

## 7. UI changes

**Empty / setup state.** Primary button: **"Sign in with Claude"**. The six-step DevTools instructions move into a collapsed *"Paste cookie manually (advanced)"* disclosure, retained as an escape hatch. The "use a separate browser or private window" tip (`:2577`) is deleted — it is no longer true.

**Accounts list.** Each row shows name, email, a state dot, and `expires in N days` when ≤ 7. A row in `.needsSignIn` gets its own **Sign in again** button. Other rows keep working normally.

**Popover banner.** Replaces the `error == "HTTP 403"` string match at `:1898` with a state-driven, per-account banner.

**Menu bar.** Percentages unchanged; a subtle `!` appears when any account needs sign-in.

**Notifications.** At T-3 days, at most once per day: *"Claude sign-in for <name> expires in N days."* Gated by a new `sessionNotificationsEnabled` setting, default on, separate from usage-threshold notifications.

## 8. Migration

One-shot, guarded by `migrated_keychain_v1`:

1. Read `accounts_v2` from `UserDefaults`.
2. For each account, parse its `cookie` string through `CookiePolicy`, keeping only allowlisted entries.
3. Write to the Keychain; clear the `cookie` field from the stored struct; **remove the legacy `claude_session_cookie` mirror** (`:547`).

Pasted strings carry no expiry metadata, so `expiresAt` is `nil` after migration. The UI must show *"expiry unknown"* rather than a fabricated countdown; the value populates on the first `Set-Cookie` or successful renewal, and until then the account is treated as `.healthy` and corrected by the reactive ladder.

**Accepted trade-off:** removing the legacy mirror means downgrading to an older build loses authentication and requires re-setup. Approved; note it in release notes.

## 9. Code structure, build, and testing

The auth code is roughly 600 new lines and `ClaudeUsageBar.swift` is already 2789. Split out:

```
app/Core/CookiePolicy.swift        # pure: allowlist, parsing, expiry extraction
app/Core/SessionState.swift        # pure: state derivation ladder
app/Core/Migration.swift           # pure: legacy plist -> keychain transform
app/Auth/KeychainStore.swift       # Security.framework
app/Auth/ClaudeSession.swift       # URLSession
app/Auth/SessionRenewal.swift      # WebKit
app/Auth/AccountStore.swift        # UserDefaults + Keychain coordination
app/UI/AccountLoginWindow.swift    # AppKit + WebKit
```

The split is deliberate: `app/Core` depends only on Foundation, so it is testable headlessly. Everything with a platform dependency lives outside it.

`build.sh` must compile the subdirectories too — a flat `*.swift` glob does not recurse. Replace the single named file with an explicit collection, e.g.:

```sh
SOURCES=$(find . -name '*.swift' -not -path './build/*' -not -path './.build/*')
swiftc -parse-as-library -o "$APP_PATH/Contents/MacOS/ClaudeUsageBar_arm64" $SOURCES ...
```

`WebKit` is already linked in `build.sh` and currently unused, so no linker change is needed.

**Automated tests.** Add a `Package.swift` at the repo root with a `ClaudeUsageBarCore` library target at `path: "app/Core"` and a test target depending on it. Those sources compile twice — once by SPM for tests, once by `swiftc` into the app — with no duplicated source and no platform dependencies to stub. Covered:

- `CookiePolicy` allowlist filtering, including that Cloudflare and analytics cookies are dropped
- `CookiePolicy` parsing of legacy pasted strings, including malformed input
- `sessionKey` expiry extraction
- `SessionState` derivation across the full ladder — the highest-value target
- Rotation diffing (change detected / no change / cookie disappeared)
- The migration transform

**Manual checklist** for the network and WebKit paths:

1. Fresh install → Sign in with Claude → Google → account appears and usage renders
2. Add a second, different account → both track independently, no cookie collision
3. Quit and relaunch → both still work (Keychain round-trip)
4. Upgrade from a build with a pasted cookie → migrates silently; plist no longer contains the cookie
5. Corrupt a stored `sessionKey` → that account shows `.needsSignIn`, the other is unaffected, one click restores it
6. Complete a Google login and let the page close the popup → **no crash** (§2.8 regression guard)
7. Remove an account → its Keychain item is gone (`security find-generic-password`)

## 10. Risks and open questions

1. **Does claude.ai slide `sessionKey` near expiry?** Unknown, and untestable 28 days out. `ClaudeSession` logs every observed change; revisit after ~6 weeks of real usage. If it does, §5.5 already captures it and users genuinely stop re-authenticating. The design is correct either way.
2. **Google could begin blocking embedded webviews.** Mitigated by retaining the paste fallback; check 6 guards the popup path.
3. **claude.ai could start requiring Cloudflare cookies.** Inherently handled: the renewal webview can supply fresh ones, and because a single UA constant is shared between webview and native session, they would remain valid.
4. **Keychain prompts on identity change.** Local ad-hoc-signed dev builds have a different identity from the Developer ID release and may prompt. Developer-only; document, do not engineer around.
5. **Downgrade breaks auth** (§8). Accepted.

## 11. Out of scope

Usage parsing and thresholds, the status page, the update banner, notification content beyond the new expiry notice, and the website.
