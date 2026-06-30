import Foundation
import Security
import Testing
@testable import PassSyncCore

@Test func appleKeychainUpdateAttributesClearMissingNotes() throws {
    let record = CredentialRecord(
        provider: .onePassword,
        title: "Example",
        username: "user@example.test",
        password: "secret",
        urls: ["https://example.test/login"],
        notes: nil
    )

    let attributes = AppleKeychainClient().keychainUpdateAttributes(for: record)

    #expect(attributes[kSecAttrComment as String] as? String == "")
}

@Test func appleKeychainUpdateAttributesPreserveProvidedNotes() throws {
    let record = CredentialRecord(
        provider: .onePassword,
        title: "Example",
        username: "user@example.test",
        password: "secret",
        urls: ["https://example.test/login"],
        notes: "new note"
    )

    let attributes = AppleKeychainClient().keychainUpdateAttributes(for: record)

    #expect(attributes[kSecAttrComment as String] as? String == "new note")
}
