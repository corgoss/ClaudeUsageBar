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

    try store.delete(for: accountId)
    expect(true, "deleting a missing item is a no-op")
} catch {
    print("  FAIL  threw: \(error)")
    failures += 1
}

print(failures == 0 ? "\nALL KEYCHAIN CHECKS PASSED" : "\n\(failures) KEYCHAIN CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)