import Testing
@testable import PassSyncCore

@Test func restoreVerifierPassesWhenProviderMatchesBackup() {
    let record = CredentialRecord(
        provider: .onePassword,
        title: "Example",
        username: "user@example.test",
        password: "secret",
        urls: ["https://example.test/login"]
    )
    let backup = BackupPayload(onePasswordRecords: [record], appleRecords: [], warnings: [])

    let report = RestoreVerifier().verify(
        backup: backup,
        currentRecords: [record],
        target: .onePassword
    )

    #expect(report.passed)
    #expect(report.passCount == 1)
    #expect(report.failureCount == 0)
}

@Test func restoreVerifierFailsWhenProviderIsMissingBackupRecord() {
    let record = CredentialRecord(
        provider: .onePassword,
        title: "Example",
        username: "user@example.test",
        password: "secret",
        urls: ["https://example.test/login"]
    )
    let backup = BackupPayload(onePasswordRecords: [record], appleRecords: [], warnings: [])

    let report = RestoreVerifier().verify(
        backup: backup,
        currentRecords: [],
        target: .onePassword
    )

    #expect(!report.passed)
    #expect(report.failureCount == 1)
    #expect(report.issues[0].title == "Missing from provider")
}

@Test func restoreVerifierFailsWithFieldDiffsWhenProviderDiffersFromBackup() {
    let backupRecord = CredentialRecord(
        provider: .onePassword,
        title: "Example",
        username: "user@example.test",
        password: "backup-secret",
        urls: ["https://example.test/login"]
    )
    let currentRecord = CredentialRecord(
        provider: .onePassword,
        title: "Example",
        username: "user@example.test",
        password: "current-secret",
        urls: ["https://example.test/login"]
    )
    let backup = BackupPayload(onePasswordRecords: [backupRecord], appleRecords: [], warnings: [])

    let report = RestoreVerifier().verify(
        backup: backup,
        currentRecords: [currentRecord],
        target: .onePassword
    )

    #expect(!report.passed)
    #expect(report.failureCount == 1)
    #expect(report.issues[0].fieldDiffs.contains { $0.field == .password })
}

@Test func restoreVerifierWarnsForExtraCurrentProviderRecord() {
    let currentRecord = CredentialRecord(
        provider: .onePassword,
        title: "Extra",
        username: "extra@example.test",
        password: "current-secret",
        urls: ["https://extra.example.test/login"]
    )
    let backup = BackupPayload(onePasswordRecords: [], appleRecords: [], warnings: [])

    let report = RestoreVerifier().verify(
        backup: backup,
        currentRecords: [currentRecord],
        target: .onePassword
    )

    #expect(report.passed)
    #expect(report.warningCount == 1)
    #expect(report.issues[0].title == "Extra current record")
}
