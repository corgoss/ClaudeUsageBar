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
       "no manual Cookie header - the jar must attach cookies")
expect(request.value(forHTTPHeaderField: "User-Agent") == ClaudeSession.userAgent,
       "carries the shared User-Agent")
expect(request.url?.absoluteString == "https://claude.ai/api/organizations/org-1/usage",
       "builds the expected URL")
expect(session.currentCookies.contains { $0.name == "sessionKey" },
       "seeded cookie is present in the private jar")

let withCloudflare = ClaudeSession(accountId: "check2", cookies: [
    cookie,
    HTTPCookie(properties: [
        .domain: ".claude.ai", .path: "/", .name: "cf_clearance", .value: "x",
    ])!,
])
expect(!withCloudflare.currentCookies.contains { $0.name == "cf_clearance" },
       "Cloudflare cookies are filtered out of the jar")

let other = ClaudeSession(accountId: "check3", cookies: [])
expect(other.currentCookies.isEmpty, "sessions are isolated from one another")

print(failures == 0 ? "\nALL SESSION CHECKS PASSED" : "\n\(failures) SESSION CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)