import Testing
@testable import PassSyncCore

@Test func planDecisionExportRedactsSecretDiffsAndDefaultsConflictToSkip() {
    let onePassword = CredentialRecord(
        provider: .onePassword,
        title: "Example",
        username: "user@example.test",
        password: "one-secret",
        urls: ["https://example.test/login"]
    )
    let apple = CredentialRecord(
        provider: .applePasswords,
        title: "Example",
        username: "user@example.test",
        password: "apple-secret",
        urls: ["https://example.test/login"]
    )
    let plan = SyncPlanner().buildPlan(
        onePasswordRecords: [onePassword],
        appleRecords: [apple],
        options: SyncOptions(direction: .bidirectional)
    )

    let decisionFile = PlanDecisionFiles.export(from: plan)

    #expect(decisionFile.format == "passsync.plan-decisions.v2")
    #expect(decisionFile.decisions[0].evidenceFingerprint != nil)
    #expect(decisionFile.decisions[0].decision == .skip)
    #expect(decisionFile.decisions[0].fieldDiffs[0].sourceValue == "<redacted:10>")
    #expect(decisionFile.decisions[0].fieldDiffs[0].destinationValue == "<redacted:12>")
}

@Test func planDecisionCanSelectOnePasswordAsConflictWinner() {
    let onePassword = CredentialRecord(
        provider: .onePassword,
        title: "Example",
        username: "user@example.test",
        password: "one-secret",
        urls: ["https://example.test/login"]
    )
    let apple = CredentialRecord(
        provider: .applePasswords,
        title: "Example",
        username: "user@example.test",
        password: "apple-secret",
        urls: ["https://example.test/login"]
    )
    let plan = SyncPlanner().buildPlan(
        onePasswordRecords: [onePassword],
        appleRecords: [apple],
        options: SyncOptions(direction: .bidirectional)
    )
    var decisions = PlanDecisionFiles.export(from: plan)
    decisions.decisions[0].decision = .useOnePassword

    let reviewed = PlanDecisionFiles.apply(decisions, to: plan)

    #expect(reviewed.actions.count == 1)
    #expect(reviewed.actions[0].kind == .updateApple)
    #expect(reviewed.actions[0].sourceRecord?.password == "one-secret")
}

@Test func planDecisionFieldMergeCanUpdateBothProviders() {
    let onePassword = CredentialRecord(
        provider: .onePassword,
        title: "One Title",
        username: "user@example.test",
        password: "one-secret",
        urls: ["https://example.test/login"],
        notes: "one notes"
    )
    let apple = CredentialRecord(
        provider: .applePasswords,
        title: "Apple Title",
        username: "user@example.test",
        password: "apple-secret",
        urls: ["https://example.test/login"],
        notes: "apple notes"
    )
    let plan = SyncPlanner().buildPlan(
        onePasswordRecords: [onePassword],
        appleRecords: [apple],
        options: SyncOptions(direction: .bidirectional)
    )
    var decisions = PlanDecisionFiles.export(from: plan)
    decisions.decisions[0].decision = .mergeFields
    decisions.decisions[0].fieldDecisions = [
        PlanFieldDecision(field: .title, provider: .applePasswords),
        PlanFieldDecision(field: .password, provider: .onePassword),
        PlanFieldDecision(field: .notes, provider: .applePasswords)
    ]

    let reviewed = PlanDecisionFiles.apply(decisions, to: plan)

    #expect(reviewed.actions.map(\.kind) == [.updateOnePassword, .updateApple])
    #expect(reviewed.actions.allSatisfy { $0.sourceRecord?.title == "Apple Title" })
    #expect(reviewed.actions.allSatisfy { $0.sourceRecord?.password == "one-secret" })
    #expect(reviewed.actions.allSatisfy { $0.sourceRecord?.notes == "apple notes" })
}

@Test func planDecisionFieldMergeBlocksWhenAChangedFieldIsMissingDecision() {
    let onePassword = CredentialRecord(
        provider: .onePassword,
        title: "One Title",
        username: "user@example.test",
        password: "one-secret",
        urls: ["https://example.test/login"]
    )
    let apple = CredentialRecord(
        provider: .applePasswords,
        title: "Apple Title",
        username: "user@example.test",
        password: "apple-secret",
        urls: ["https://example.test/login"]
    )
    let plan = SyncPlanner().buildPlan(
        onePasswordRecords: [onePassword],
        appleRecords: [apple],
        options: SyncOptions(direction: .bidirectional)
    )
    var decisions = PlanDecisionFiles.export(from: plan)
    decisions.decisions[0].decision = .mergeFields
    decisions.decisions[0].fieldDecisions = [
        PlanFieldDecision(field: .title, provider: .applePasswords)
    ]

    let reviewed = PlanDecisionFiles.apply(decisions, to: plan)

    #expect(reviewed.actions.count == 1)
    #expect(reviewed.actions[0].kind == .unsupported)
    #expect(reviewed.actions[0].reason.contains("password"))
}

@Test func planDecisionBlocksStaleDecisionWhenCurrentEvidenceChanges() {
    let onePassword = CredentialRecord(
        provider: .onePassword,
        title: "Example",
        username: "user@example.test",
        password: "one-secret",
        urls: ["https://example.test/login"]
    )
    let apple = CredentialRecord(
        provider: .applePasswords,
        title: "Example",
        username: "user@example.test",
        password: "apple-secret",
        urls: ["https://example.test/login"]
    )
    let originalPlan = SyncPlanner().buildPlan(
        onePasswordRecords: [onePassword],
        appleRecords: [apple],
        options: SyncOptions(direction: .bidirectional)
    )
    var decisions = PlanDecisionFiles.export(from: originalPlan)
    decisions.decisions[0].decision = .useOnePassword

    var changedOnePassword = onePassword
    changedOnePassword.password = "new-secret"
    let changedPlan = SyncPlanner().buildPlan(
        onePasswordRecords: [changedOnePassword],
        appleRecords: [apple],
        options: SyncOptions(direction: .bidirectional)
    )

    let reviewed = PlanDecisionFiles.apply(decisions, to: changedPlan)

    #expect(reviewed.actions.count == 1)
    #expect(reviewed.actions[0].kind == .unsupported)
    #expect(reviewed.actions[0].reason.contains("Decision evidence no longer matches"))
}

@Test func planDecisionBlocksStaleMergeWhenNewFieldDiffAppears() {
    let onePassword = CredentialRecord(
        provider: .onePassword,
        title: "One Title",
        username: "user@example.test",
        password: "one-secret",
        urls: ["https://example.test/login"]
    )
    let apple = CredentialRecord(
        provider: .applePasswords,
        title: "Apple Title",
        username: "user@example.test",
        password: "apple-secret",
        urls: ["https://example.test/login"]
    )
    let originalPlan = SyncPlanner().buildPlan(
        onePasswordRecords: [onePassword],
        appleRecords: [apple],
        options: SyncOptions(direction: .bidirectional)
    )
    var decisions = PlanDecisionFiles.export(from: originalPlan)
    decisions.decisions[0].decision = .mergeFields
    decisions.decisions[0].fieldDecisions = [
        PlanFieldDecision(field: .title, provider: .applePasswords),
        PlanFieldDecision(field: .password, provider: .onePassword)
    ]

    var changedApple = apple
    changedApple.notes = "new apple note"
    let changedPlan = SyncPlanner().buildPlan(
        onePasswordRecords: [onePassword],
        appleRecords: [changedApple],
        options: SyncOptions(direction: .bidirectional)
    )

    let reviewed = PlanDecisionFiles.apply(decisions, to: changedPlan)

    #expect(reviewed.actions.count == 1)
    #expect(reviewed.actions[0].kind == .unsupported)
    #expect(reviewed.actions[0].reason.contains("Decision evidence no longer matches"))
}
