import Testing
@testable import PassSyncCore

@Test func canonicalHostStripsWWWAndHandlesBareDomain() {
    #expect(URLUtilities.canonicalHost(from: "https://www.example.com/login") == "example.com")
    #expect(URLUtilities.canonicalHost(from: "example.com") == "example.com")
}

@Test func credentialKeyUsesFirstURLAndLowercasesUsername() {
    let record = CredentialRecord(
        provider: .onePassword,
        title: "Example",
        username: "USER@EXAMPLE.COM",
        password: "secret",
        urls: ["https://www.example.com/login"]
    )

    let key = URLUtilities.key(for: record)
    #expect(key == CredentialKey(host: "example.com", username: "user@example.com"))
}

