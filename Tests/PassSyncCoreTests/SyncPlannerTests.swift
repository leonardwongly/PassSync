import Foundation
import Testing
@testable import PassSyncCore

@Test func plannerCreatesMissingAppleRecord() {
    let oneP = CredentialRecord(
        provider: .onePassword,
        title: "Example",
        username: "user@example.com",
        password: "secret",
        urls: ["https://example.com/login"]
    )

    let plan = SyncPlanner().buildPlan(
        onePasswordRecords: [oneP],
        appleRecords: [],
        options: SyncOptions(direction: .onePasswordToApple)
    )

    #expect(plan.actions.count == 1)
    #expect(plan.actions[0].kind == .createInApple)
}

@Test func plannerBlocksPasskeyMigration() {
    let oneP = CredentialRecord(
        provider: .onePassword,
        title: "Example",
        username: "user@example.com",
        password: "secret",
        urls: ["https://example.com/login"],
        hasPasskey: true
    )

    let plan = SyncPlanner().buildPlan(
        onePasswordRecords: [oneP],
        appleRecords: [],
        options: SyncOptions(direction: .onePasswordToApple)
    )

    #expect(plan.actions.count == 1)
    #expect(plan.actions[0].kind == .unsupported)
    #expect(plan.hasBlockingActions)
}

@Test func plannerBlocksTotpToAppleByDefault() {
    let oneP = CredentialRecord(
        provider: .onePassword,
        title: "Example",
        username: "user@example.com",
        password: "secret",
        urls: ["https://example.com/login"],
        totpURI: "otpauth://totp/example:user?secret=ABC&issuer=Example"
    )

    let plan = SyncPlanner().buildPlan(
        onePasswordRecords: [oneP],
        appleRecords: [],
        options: SyncOptions(direction: .onePasswordToApple)
    )

    #expect(plan.actions[0].kind == .unsupported)
}

@Test func plannerAllowsAppleToOnePasswordTotp() {
    let apple = CredentialRecord(
        provider: .applePasswords,
        title: "Example",
        username: "user@example.com",
        password: "secret",
        urls: ["https://example.com/login"],
        totpURI: "otpauth://totp/example:user?secret=ABC&issuer=Example"
    )

    let plan = SyncPlanner().buildPlan(
        onePasswordRecords: [],
        appleRecords: [apple],
        options: SyncOptions(direction: .appleToOnePassword)
    )

    #expect(plan.actions[0].kind == .createInOnePassword)
}

@Test func conflictWithTruthSourceUpdatesDestination() {
    let oneP = CredentialRecord(
        provider: .onePassword,
        title: "Example",
        username: "user@example.com",
        password: "one",
        urls: ["https://example.com/login"]
    )
    let apple = CredentialRecord(
        provider: .applePasswords,
        title: "Example",
        username: "user@example.com",
        password: "two",
        urls: ["https://example.com/login"]
    )

    let plan = SyncPlanner().buildPlan(
        onePasswordRecords: [oneP],
        appleRecords: [apple],
        options: SyncOptions(direction: .bidirectional, truthSource: .onePassword)
    )

    #expect(plan.actions[0].kind == .updateApple)
}

@Test func redactedPlanDoesNotExposeSecrets() throws {
    let oneP = CredentialRecord(
        provider: .onePassword,
        title: "Example",
        username: "user@example.com",
        password: "super-secret",
        urls: ["https://example.com/login"],
        totpURI: "otpauth://totp/example:user?secret=ABC&issuer=Example"
    )
    let plan = SyncPlan(
        direction: .onePasswordToApple,
        truthSource: .none,
        conflictPolicy: .interactive,
        actions: [
            SyncAction(kind: .unsupported, key: CredentialKey(host: "example.com", username: "user@example.com"), source: .onePassword, destination: .applePasswords, reason: "test", sourceRecord: oneP)
        ],
        warnings: []
    )
    let redacted = SecretRedactor.redactPlan(plan)
    let data = try JSONEncoder().encode(redacted)
    let json = String(data: data, encoding: .utf8) ?? ""
    #expect(!json.contains("super-secret"))
    #expect(!json.contains("secret=ABC"))
}

