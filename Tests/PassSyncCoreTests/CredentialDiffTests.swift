import Testing
@testable import PassSyncCore

@Test func credentialDiffRedactsSecretFields() {
    let source = CredentialRecord(
        provider: .onePassword,
        title: "Example",
        username: "user@example.test",
        password: "source-secret",
        urls: ["https://example.test/login"],
        totpURI: "otpauth://totp/example?secret=ABC"
    )
    let destination = CredentialRecord(
        provider: .applePasswords,
        title: "Example",
        username: "user@example.test",
        password: "destination-secret",
        urls: ["https://example.test/login"]
    )

    let diffs = CredentialDiff.fieldDiffs(source: source, destination: destination)

    #expect(diffs.contains { $0.field == .password && $0.sourceValue == "<redacted:13>" })
    #expect(diffs.contains { $0.field == .totpURI && $0.sourceValue.hasPrefix("<redacted:") })
    #expect(!diffs.contains { $0.sourceValue.contains("source-secret") })
    #expect(!diffs.contains { $0.sourceValue.contains("secret=ABC") })
}
