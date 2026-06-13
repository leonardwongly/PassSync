import Testing
@testable import PassSyncCore

@Test func simulationApplyCreatesAppleRecordWithoutMutatingInputState() throws {
    let source = CredentialRecord(
        provider: .onePassword,
        sourceID: "onep-1",
        vaultID: "Test",
        title: "Example",
        username: "user@example.com",
        password: "secret",
        urls: ["https://example.com/login"]
    )
    let input = SimulationState(onePasswordRecords: [source], appleRecords: [])
    let store = SimulationStore(state: input)
    let plan = SyncPlanner().buildPlan(
        onePasswordRecords: try store.fetchLogins(vault: "Test"),
        appleRecords: try store.fetchLogins(),
        options: SyncOptions(direction: .onePasswordToApple)
    )

    try SyncExecutor(onePassword: store, applePasswords: store).apply(plan: plan, onePasswordVault: "Test")

    #expect(input.appleRecords.isEmpty)
    #expect(store.state.appleRecords.count == 1)
    #expect(store.state.appleRecords[0].provider == .applePasswords)
    #expect(store.state.appleRecords[0].password == "secret")
}

@Test func simulationAppleCompatibilityDropsTotpOnlyAfterExplicitPlannerAllowance() throws {
    let source = CredentialRecord(
        provider: .onePassword,
        sourceID: "onep-1",
        vaultID: "Test",
        title: "Example",
        username: "user@example.com",
        password: "secret",
        urls: ["https://example.com/login"],
        totpURI: "otpauth://totp/example:user?secret=ABC&issuer=Example"
    )
    let store = SimulationStore(state: SimulationState(onePasswordRecords: [source], appleRecords: []))
    let blockedPlan = SyncPlanner().buildPlan(
        onePasswordRecords: try store.fetchLogins(vault: "Test"),
        appleRecords: try store.fetchLogins(),
        options: SyncOptions(direction: .onePasswordToApple)
    )
    #expect(blockedPlan.actions[0].kind == .unsupported)

    let allowedPlan = SyncPlanner().buildPlan(
        onePasswordRecords: try store.fetchLogins(vault: "Test"),
        appleRecords: try store.fetchLogins(),
        options: SyncOptions(
            direction: .onePasswordToApple,
            allowPasswordOnlyForUnsupportedSecurityMaterial: true
        )
    )

    try SyncExecutor(onePassword: store, applePasswords: store).apply(plan: allowedPlan, onePasswordVault: "Test")

    #expect(store.state.appleRecords.count == 1)
    #expect(store.state.appleRecords[0].totpURI == nil)
}

@Test func simulationAppleToOnePasswordKeepsTotpSecret() throws {
    let source = CredentialRecord(
        provider: .applePasswords,
        sourceID: "apple-1",
        title: "Example",
        username: "user@example.com",
        password: "secret",
        urls: ["https://example.com/login"],
        totpURI: "otpauth://totp/example:user?secret=ABC&issuer=Example"
    )
    let store = SimulationStore(state: SimulationState(onePasswordRecords: [], appleRecords: [source]))
    let plan = SyncPlanner().buildPlan(
        onePasswordRecords: try store.fetchLogins(vault: nil),
        appleRecords: try store.fetchLogins(),
        options: SyncOptions(direction: .appleToOnePassword)
    )

    try SyncExecutor(onePassword: store, applePasswords: store).apply(plan: plan, onePasswordVault: "Test")

    #expect(store.state.onePasswordRecords.count == 1)
    #expect(store.state.onePasswordRecords[0].totpURI == source.totpURI)
    #expect(store.state.onePasswordRecords[0].vaultID == "Test")
}
