import Testing
@testable import PassSyncCore

@Test func syncExecutorRefusesTotpAppleMutationWithoutExplicitAllowance() throws {
    let onePassword = RecordingOnePasswordManager()
    let apple = RecordingApplePasswordsManager()
    let source = CredentialRecord(
        provider: .onePassword,
        title: "Example",
        username: "user@example.test",
        password: "secret",
        urls: ["https://example.test/login"],
        totpURI: "otpauth://totp/example?secret=ABC"
    )
    let plan = SyncPlan(
        direction: .onePasswordToApple,
        truthSource: .onePassword,
        conflictPolicy: .fail,
        actions: [
            SyncAction(
                kind: .createInApple,
                key: CredentialKey(host: "example.test", username: "user@example.test"),
                source: .onePassword,
                destination: .applePasswords,
                reason: "hand-built",
                sourceRecord: source
            )
        ],
        warnings: []
    )

    do {
        try SyncExecutor(onePassword: onePassword, applePasswords: apple).apply(plan: plan)
        Issue.record("Expected TOTP-bearing Apple write to fail closed.")
    } catch let error as PassSyncError {
        #expect(error.description.contains("cannot receive TOTP material"))
    }

    #expect(apple.created.isEmpty)
    #expect(apple.updated.isEmpty)
}

@Test func syncExecutorAllowsExplicitPasswordOnlyAppleMutation() throws {
    let onePassword = RecordingOnePasswordManager()
    let apple = RecordingApplePasswordsManager()
    let source = CredentialRecord(
        provider: .onePassword,
        title: "Example",
        username: "user@example.test",
        password: "secret",
        urls: ["https://example.test/login"],
        totpURI: "otpauth://totp/example?secret=ABC"
    )
    let plan = SyncPlan(
        direction: .onePasswordToApple,
        truthSource: .onePassword,
        conflictPolicy: .fail,
        actions: [
            SyncAction(
                kind: .createInApple,
                key: CredentialKey(host: "example.test", username: "user@example.test"),
                source: .onePassword,
                destination: .applePasswords,
                reason: "hand-built",
                sourceRecord: source
            )
        ],
        warnings: []
    )

    try SyncExecutor(
        onePassword: onePassword,
        applePasswords: apple,
        allowPasswordOnlyForUnsupportedSecurityMaterial: true
    ).apply(plan: plan)

    #expect(apple.created.count == 1)
}

@Test func syncExecutorRefusesPasskeyMutationForAnyProvider() throws {
    let onePassword = RecordingOnePasswordManager()
    let apple = RecordingApplePasswordsManager()
    let source = CredentialRecord(
        provider: .applePasswords,
        title: "Example",
        username: "user@example.test",
        password: "secret",
        urls: ["https://example.test/login"],
        hasPasskey: true
    )
    let plan = SyncPlan(
        direction: .appleToOnePassword,
        truthSource: .applePasswords,
        conflictPolicy: .fail,
        actions: [
            SyncAction(
                kind: .createInOnePassword,
                key: CredentialKey(host: "example.test", username: "user@example.test"),
                source: .applePasswords,
                destination: .onePassword,
                reason: "hand-built",
                sourceRecord: source
            )
        ],
        warnings: []
    )

    do {
        try SyncExecutor(onePassword: onePassword, applePasswords: apple).apply(plan: plan)
        Issue.record("Expected passkey-bearing mutation to fail closed.")
    } catch let error as PassSyncError {
        #expect(error.description.contains("source contains passkey evidence"))
    }

    #expect(onePassword.created.isEmpty)
    #expect(onePassword.updated.isEmpty)
}

private final class RecordingOnePasswordManager: OnePasswordManaging, @unchecked Sendable {
    private(set) var created: [CredentialRecord] = []
    private(set) var updated: [CredentialRecord] = []

    func fetchLogins(vault _: String?) throws -> [CredentialRecord] { [] }

    func create(_ record: CredentialRecord, vault _: String?) throws {
        created.append(record)
    }

    func update(_ record: CredentialRecord, existing _: CredentialRecord, vault _: String?) throws {
        updated.append(record)
    }
}

private final class RecordingApplePasswordsManager: ApplePasswordsManaging, @unchecked Sendable {
    private(set) var created: [CredentialRecord] = []
    private(set) var updated: [CredentialRecord] = []

    func fetchLogins() throws -> [CredentialRecord] { [] }

    func create(_ record: CredentialRecord) throws {
        created.append(record)
    }

    func update(_ record: CredentialRecord, existing _: CredentialRecord) throws {
        updated.append(record)
    }
}
