import Foundation
import Security

public protocol ApplePasswordsManaging: Sendable {
    func fetchLogins() throws -> [CredentialRecord]
    func create(_ record: CredentialRecord) throws
    func update(_ record: CredentialRecord, existing: CredentialRecord) throws
}

public struct AppleKeychainClient: ApplePasswordsManaging {
    public init() {}

    public func fetchLogins() throws -> [CredentialRecord] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            throw PassSyncError.keychainError(operation: "read internet passwords", status: status)
        }

        guard let items = result as? [[String: Any]] else {
            return []
        }

        return items.compactMap(mapKeychainItem)
    }

    public func create(_ record: CredentialRecord) throws {
        guard let attributes = keychainAttributes(for: record, includeValue: true) else {
            throw PassSyncError.invalidArguments("Cannot create Apple Passwords item without a URL host.")
        }

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard let existing = try fetchLogins().first(where: { URLUtilities.key(for: $0) == URLUtilities.key(for: record) }) else {
                throw PassSyncError.keychainError(operation: "resolve duplicate internet password", status: status)
            }
            try update(record, existing: existing)
            return
        }
        guard status == errSecSuccess else {
            throw PassSyncError.keychainError(operation: "create internet password", status: status)
        }
    }

    public func update(_ record: CredentialRecord, existing: CredentialRecord) throws {
        guard let query = keychainQuery(for: existing) else {
            throw PassSyncError.invalidArguments("Cannot update Apple Passwords item without a URL host.")
        }
        let attributes = keychainUpdateAttributes(for: record)
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess else {
            throw PassSyncError.keychainError(operation: "update internet password", status: status)
        }
    }

    private func mapKeychainItem(_ item: [String: Any]) -> CredentialRecord? {
        guard let account = item[kSecAttrAccount as String] as? String,
              let server = item[kSecAttrServer as String] as? String,
              let data = item[kSecValueData as String] as? Data,
              let password = String(data: data, encoding: .utf8),
              !account.isEmpty,
              !server.isEmpty,
              !password.isEmpty else {
            return nil
        }

        let path = item[kSecAttrPath as String] as? String
        let label = item[kSecAttrLabel as String] as? String
        let comment = item[kSecAttrComment as String] as? String
        let modifiedAt = item[kSecAttrModificationDate as String] as? Date
        let url = "https://\(server)\(path ?? "")"

        return CredentialRecord(
            provider: .applePasswords,
            sourceID: [server, account, path ?? ""].joined(separator: "|"),
            title: label ?? server,
            username: account,
            password: password,
            urls: [url],
            notes: comment,
            totpURI: nil,
            hasPasskey: false,
            modifiedAt: modifiedAt,
            rawFingerprint: SHA256Fingerprint.hex(data)
        )
    }

    private func keychainAttributes(for record: CredentialRecord, includeValue: Bool) -> [String: Any]? {
        guard let url = URLUtilities.primaryURL(for: record),
              let host = url.host(percentEncoded: false) else {
            return nil
        }

        var attributes: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: record.username,
            kSecAttrLabel as String: record.title,
            kSecAttrDescription as String: record.title,
            kSecAttrSynchronizable as String: true
        ]

        if !url.path.isEmpty {
            attributes[kSecAttrPath as String] = url.path
        }
        if let protocolValue = protocolAttribute(for: url.scheme) {
            attributes[kSecAttrProtocol as String] = protocolValue
        }
        if let notes = record.notes, !notes.isEmpty {
            attributes[kSecAttrComment as String] = notes
        }
        if includeValue {
            attributes[kSecValueData as String] = Data(record.password.utf8)
        }
        return attributes
    }

    private func keychainQuery(for record: CredentialRecord) -> [String: Any]? {
        guard let url = URLUtilities.primaryURL(for: record),
              let host = url.host(percentEncoded: false) else {
            return nil
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: record.username,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        if !url.path.isEmpty {
            query[kSecAttrPath as String] = url.path
        }
        return query
    }

    private func keychainUpdateAttributes(for record: CredentialRecord) -> [String: Any] {
        var attributes: [String: Any] = [
            kSecValueData as String: Data(record.password.utf8),
            kSecAttrLabel as String: record.title,
            kSecAttrDescription as String: record.title
        ]
        if let notes = record.notes {
            attributes[kSecAttrComment as String] = notes
        }
        return attributes
    }

    private func protocolAttribute(for scheme: String?) -> CFString? {
        switch scheme?.lowercased() {
        case "https":
            return kSecAttrProtocolHTTPS
        case "http":
            return kSecAttrProtocolHTTP
        case "ftp":
            return kSecAttrProtocolFTP
        default:
            return nil
        }
    }
}
