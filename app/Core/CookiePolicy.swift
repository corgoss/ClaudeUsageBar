import Foundation

public enum CookiePolicy {

	public static let allowlist: Set<String> = [
		"sessionKey",
		"sessionKeyLC",
		"lastActiveOrg",
		"routingHint",
		"anthropic-device-id",
	]

	public static func filter(_ cookies: [HTTPCookie]) -> [HTTPCookie] {
		cookies.filter { allowlist.contains($0.name) }
	}

	public static func parse(pasted: String) -> [HTTPCookie] {
		var input = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
		if input.lowercased().hasPrefix("cookie:") {
			input = String(input.dropFirst("cookie:".count))
		}

		return input.components(separatedBy: ";").compactMap { part in
			let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
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