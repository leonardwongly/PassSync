import Testing
@testable import PassSyncCore

@Test func restorePlannerCreatesMissingOnePasswordRecord() {
    let record = CredentialRecord(
        provider: .onePassword,
        title: "Example",
        username: "user@example.test",
        password: "secret",
        urls: ["https://example.test/login"]
    )
    let backup = BackupPayload(onePasswordRecords: [record], appleRecords: [], warnings: [])

    let plan = RestorePlanner().buildPlan(backup: backup, currentRecords: [], target: .onePassword)

    #expect(plan.actions.count == 1)
    #expect(plan.actions[0].kind == .createInOnePassword)
}

@Test func restorePlannerBlocksPasskeyEvidence() {
    let record = CredentialRecord(
        provider: .onePassword,
        title: "Example",
        username: "user@example.test",
        password: "secret",
        urls: ["https://example.test/login"],
        hasPasskey: true
    )
    let backup = BackupPayload(onePasswordRecords: [record], appleRecords: [], warnings: [])

    let plan = RestorePlanner().buildPlan(backup: backup, currentRecords: [], target: .onePassword)

    #expect(plan.actions[0].kind == .unsupported)
    #expect(plan.hasBlockingActions)
}

@Test func restorePlannerBlocksAppleTotpUnlessExplicitlyAllowed() {
    let record = CredentialRecord(
        provider: .applePasswords,
        title: "Example",
        username: "user@example.test",
        password: "secret",
        urls: ["https://example.test/login"],
        totpURI: "otpauth://totp/example?secret=ABC"
    )
    let backup = BackupPayload(onePasswordRecords: [], appleRecords: [record], warnings: [])

    let blocked = RestorePlanner().buildPlan(backup: backup, currentRecords: [], target: .applePasswords)
    let allowed = RestorePlanner().buildPlan(
        backup: backup,
        currentRecords: [],
        target: .applePasswords,
        allowPasswordOnlyForUnsupportedSecurityMaterial: true
    )

    #expect(blocked.actions[0].kind == .unsupported)
    #expect(allowed.actions[0].kind == .createInApple)
}

@Test func restorePlanAppliesToSimulationStore() throws {
    let record = CredentialRecord(
        provider: .onePassword,
        title: "Example",
        username: "user@example.test",
        password: "secret",
        urls: ["https://example.test/login"]
    )
    let backup = BackupPayload(onePasswordRecords: [record], appleRecords: [], warnings: [])
    let store = SimulationStore(state: SimulationState(onePasswordRecords: [], appleRecords: []))
    let plan = RestorePlanner().buildPlan(backup: backup, currentRecords: [], target: .onePassword)

    try SyncExecutor(onePassword: store, applePasswords: store).apply(plan: plan, onePasswordVault: "Restored")

    #expect(store.state.onePasswordRecords.count == 1)
    #expect(store.state.onePasswordRecords[0].vaultID == "Restored")
}
