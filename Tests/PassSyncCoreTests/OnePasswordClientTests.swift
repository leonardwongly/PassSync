import Foundation
import Testing
@testable import PassSyncCore

@Test func onePasswordClientParsesLoginTotpAndPasskeyEvidence() throws {
    let runner = MockRunner(results: [
        ProcessResult(stdout: Data(#"[{"id":"item-1"}]"#.utf8), stderr: Data(), status: 0),
        ProcessResult(stdout: Data("""
        {
          "id": "item-1",
          "title": "Example",
          "category": "LOGIN",
          "vault": {"id": "vault-1"},
          "updated_at": "2026-06-13T00:00:00Z",
          "urls": [{"href": "https://example.com/login"}],
          "fields": [
            {"id": "username", "type": "STRING", "purpose": "USERNAME", "label": "username", "value": "user@example.com"},
            {"id": "password", "type": "CONCEALED", "purpose": "PASSWORD", "label": "password", "value": "secret"},
            {"id": "notesPlain", "type": "STRING", "purpose": "NOTES", "label": "notesPlain", "value": "note"},
            {"id": "otp", "type": "OTP", "label": "otp", "value": "otpauth://totp/example:user?secret=ABC&issuer=Example"}
          ],
          "passkey": {"credentialId": "abc"}
        }
        """.utf8), stderr: Data(), status: 0)
    ])
    let client = OnePasswordClient(runner: runner, opPath: "/mock/op")

    let records = try client.fetchLogins(vault: "Private")

    #expect(records.count == 1)
    #expect(records[0].title == "Example")
    #expect(records[0].username == "user@example.com")
    #expect(records[0].password == "secret")
    #expect(records[0].totpURI?.hasPrefix("otpauth://") == true)
    #expect(records[0].hasPasskey)
}

@Test func onePasswordCreateSendsSecretsOnStdinNotArguments() throws {
    let runner = MockRunner(results: [
        ProcessResult(stdout: Data("{}".utf8), stderr: Data(), status: 0)
    ])
    let client = OnePasswordClient(runner: runner, opPath: "/mock/op")
    let record = CredentialRecord(
        provider: .applePasswords,
        title: "Example",
        username: "user@example.com",
        password: "secret-value",
        urls: ["https://example.com/login"],
        totpURI: "otpauth://totp/example:user?secret=ABC&issuer=Example"
    )

    try client.create(record, vault: "Private")

    #expect(runner.calls.count == 1)
    #expect(!runner.calls[0].arguments.joined(separator: " ").contains("secret-value"))
    #expect(String(data: runner.calls[0].stdin ?? Data(), encoding: .utf8)?.contains("secret-value") == true)
}

@Test func onePasswordItemAuditUsesSummaryListOnly() throws {
    let runner = MockRunner(results: [
        ProcessResult(stdout: Data("""
        [
          {"id":"login-1","title":"Login","category":"LOGIN"},
          {"id":"note-1","title":"Private Note","category":"SECURE_NOTE"},
          {"id":"ssh-1","title":"SSH Key","category":"SSH_KEY"}
        ]
        """.utf8), stderr: Data(), status: 0)
    ])
    let client = OnePasswordClient(runner: runner, opPath: "/mock/op")

    let report = try client.auditItemCategories(vault: "Private")

    #expect(runner.calls.count == 1)
    #expect(runner.calls[0].arguments == ["item", "list", "--format", "json", "--vault", "Private"])
    #expect(report.totalCount == 3)
    #expect(report.supportedLoginCount == 1)
    #expect(report.unsupportedCount == 2)
    #expect(report.categories.contains { $0.category == "SECURE_NOTE" })
    #expect(report.categories.contains { $0.category == "SSH_KEY" })
}

@Test func onePasswordUpdateErrorDoesNotExposeItemIdentifier() throws {
    let runner = MockRunner(results: [
        ProcessResult(stdout: Data(), stderr: Data("item failed".utf8), status: 1)
    ])
    let client = OnePasswordClient(runner: runner, opPath: "/mock/op")
    let existing = CredentialRecord(
        provider: .onePassword,
        sourceID: "op-item-sensitive-id",
        title: "Example",
        username: "user@example.com",
        password: "old-secret",
        urls: ["https://example.com/login"]
    )
    let updated = CredentialRecord(
        provider: .applePasswords,
        title: "Example",
        username: "user@example.com",
        password: "new-secret",
        urls: ["https://example.com/login"]
    )

    do {
        try client.update(updated, existing: existing, vault: "Private")
        Issue.record("Expected update failure.")
    } catch let error as PassSyncError {
        #expect(error.description.contains("op item edit <item-id>"))
        #expect(!error.description.contains("op-item-sensitive-id"))
    }
}

@Test func onePasswordPasskeyRefusalDoesNotExposeItemIdentifier() throws {
    let client = OnePasswordClient(runner: MockRunner(results: []), opPath: "/mock/op")
    let existing = CredentialRecord(
        provider: .onePassword,
        sourceID: "op-item-sensitive-id",
        title: "Example",
        username: "user@example.com",
        password: "old-secret",
        urls: ["https://example.com/login"],
        hasPasskey: true
    )
    let updated = CredentialRecord(
        provider: .applePasswords,
        title: "Example",
        username: "user@example.com",
        password: "new-secret",
        urls: ["https://example.com/login"]
    )

    do {
        try client.update(updated, existing: existing, vault: "Private")
        Issue.record("Expected passkey refusal.")
    } catch let error as PassSyncError {
        #expect(error.description.contains("Refusing to edit 1Password item"))
        #expect(!error.description.contains("op-item-sensitive-id"))
    }
}

@Test func syncExecutorPassesVaultToOnePasswordMutations() throws {
    let onePassword = MockOnePasswordManager()
    let apple = MockApplePasswordsManager()
    let executor = SyncExecutor(onePassword: onePassword, applePasswords: apple)
    let record = CredentialRecord(
        provider: .applePasswords,
        title: "Example",
        username: "user@example.com",
        password: "secret",
        urls: ["https://example.com/login"]
    )
    let action = SyncAction(
        kind: .createInOnePassword,
        key: CredentialKey(host: "example.com", username: "user@example.com"),
        source: .applePasswords,
        destination: .onePassword,
        reason: "test",
        sourceRecord: record
    )
    let plan = SyncPlan(direction: .appleToOnePassword, truthSource: .none, conflictPolicy: .interactive, actions: [action], warnings: [])

    try executor.apply(plan: plan, onePasswordVault: "Private")

    #expect(onePassword.createdVaults == ["Private"])
}

private final class MockRunner: ProcessRunning, @unchecked Sendable {
    struct Call {
        var executable: String
        var arguments: [String]
        var stdin: Data?
    }

    private var results: [ProcessResult]
    private(set) var calls: [Call] = []

    init(results: [ProcessResult]) {
        self.results = results
    }

    func run(executable: String, arguments: [String], stdin: Data?) throws -> ProcessResult {
        calls.append(Call(executable: executable, arguments: arguments, stdin: stdin))
        return results.removeFirst()
    }
}

private final class MockOnePasswordManager: OnePasswordManaging, @unchecked Sendable {
    private(set) var createdVaults: [String?] = []

    func fetchLogins(vault _: String?) throws -> [CredentialRecord] { [] }

    func create(_: CredentialRecord, vault: String?) throws {
        createdVaults.append(vault)
    }

    func update(_: CredentialRecord, existing _: CredentialRecord, vault: String?) throws {
        createdVaults.append(vault)
    }
}

private struct MockApplePasswordsManager: ApplePasswordsManaging {
    func fetchLogins() throws -> [CredentialRecord] { [] }
    func create(_: CredentialRecord) throws {}
    func update(_: CredentialRecord, existing _: CredentialRecord) throws {}
}
