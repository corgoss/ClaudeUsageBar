import Foundation
import Security

#if canImport(ClaudeUsageBarCore)
import ClaudeUsageBarCore
#endif

public enum KeychainError: Error, CustomStringConvertible {
	case status(OSStatus)

	public var description: String {
		switch self {
		case .status(let status):
			let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
			return "Keychain error \(status): \(message)"
		}
	}
}

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
		let updateStatus = SecItemUpdate(baseQuery(accountId) as CFDictionary, [
			kSecValueData as String: data,
		] as CFDictionary)
		if updateStatus == errSecSuccess { return }
		guard updateStatus == errSecItemNotFound else {
			throw KeychainError.status(updateStatus)
		}

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