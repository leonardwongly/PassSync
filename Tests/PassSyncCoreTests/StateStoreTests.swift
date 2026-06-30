import Foundation
import SQLite3
import Testing
@testable import PassSyncCore

@Test func stateStoreInitializesWithEmptySummary() throws {
    let store = StateStore(path: temporaryStatePath())

    let summary = try store.summary()

    #expect(summary.path == store.path)
    #expect(summary.schemaVersion == StateStore.currentSchemaVersion)
    #expect(summary.credentialCount == 0)
    #expect(summary.decisionFileCount == 0)
    #expect(summary.receiptCount == 0)
    #expect(summary.latestObservationAt == nil)
    #expect(try store.schemaVersion() == StateStore.currentSchemaVersion)
}

@Test func stateStoreCreatesPrivateDirectoryAndDatabase() throws {
    let directory = temporaryDirectory()
    let store = StateStore(path: directory.appendingPathComponent("passsync.sqlite").path)

    _ = try store.summary()

    #expect(try SecureFileIO.permissions(at: directory.path) == 0o700)
    #expect(try SecureFileIO.permissions(at: store.path) == 0o600)
}

@Test func stateStoreMigratesUnversionedDatabaseToCurrentSchema() throws {
    let path = temporaryStatePath()
    try setSQLiteUserVersion(path: path, version: 0)
    let store = StateStore(path: path)

    try store.initialize()

    #expect(try store.schemaVersion() == StateStore.currentSchemaVersion)
}

@Test func stateStoreRefusesNewerSchemaVersion() throws {
    let path = temporaryStatePath()
    try setSQLiteUserVersion(path: path, version: StateStore.currentSchemaVersion + 1)
    let store = StateStore(path: path)

    do {
        try store.initialize()
        Issue.record("Expected newer schema version to fail closed.")
    } catch let error as PassSyncError {
        #expect(error.description.contains("newer than this PassSync build supports"))
    }
}

@Test func stateStoreRecordsNonSecretCredentialSnapshots() throws {
    let store = StateStore(path: temporaryStatePath())
    let observedAt = try #require(ISO8601DateFormatter().date(from: "2026-06-13T01:02:03Z"))
    let record = CredentialRecord(
        provider: .onePassword,
        sourceID: "item-1",
        vaultID: "Private",
        title: "Example",
        username: "user@example.test",
        password: "plain-secret",
        urls: ["https://example.test/login"],
        notes: "sensitive note",
        totpURI: "otpauth://totp/example:user@example.test?secret=SECRET&issuer=Example",
        hasPasskey: true,
        modifiedAt: observedAt,
        rawFingerprint: "raw-secret-token"
    )

    let count = try store.recordCredentials([record], observedAt: observedAt)
    let summary = try store.summary()
    let snapshots = try store.credentialSnapshots()
    let encodedSnapshots = String(data: try JSONEncoder().encode(snapshots), encoding: .utf8) ?? ""

    #expect(count == 1)
    #expect(summary.credentialCount == 1)
    #expect(summary.latestObservationAt == observedAt)
    #expect(snapshots.count == 1)
    #expect(snapshots[0].provider == .onePassword)
    #expect(!snapshots[0].keyFingerprint.isEmpty)
    #expect(snapshots[0].hasTOTP)
    #expect(snapshots[0].hasPasskey)
    #expect(!encodedSnapshots.contains("plain-secret"))
    #expect(!encodedSnapshots.contains("otpauth://"))
    #expect(!encodedSnapshots.contains("sensitive note"))
    #expect(!encodedSnapshots.contains("item-1"))
    #expect(!encodedSnapshots.contains("Private"))
    #expect(!encodedSnapshots.contains("Example"))
    #expect(!encodedSnapshots.contains("raw-secret-token"))
    let rawDatabase = try String(decoding: Data(contentsOf: URL(fileURLWithPath: store.path)), as: UTF8.self)
    #expect(!rawDatabase.contains("item-1"))
    #expect(!rawDatabase.contains("Private"))
    #expect(!rawDatabase.contains("Example"))
    #expect(!rawDatabase.contains("raw-secret-token"))
}

@Test func stateStoreUpsertsCredentialSnapshotsByProviderHostAndUsername() throws {
    let store = StateStore(path: temporaryStatePath())
    let original = CredentialRecord(
        provider: .applePasswords,
        title: "Old Title",
        username: "USER@EXAMPLE.TEST",
        password: "old-secret",
        urls: ["https://example.test/login"]
    )
    let updated = CredentialRecord(
        provider: .applePasswords,
        title: "New Title",
        username: "user@example.test",
        password: "new-secret",
        urls: ["https://example.test/login", "https://example.test/account"]
    )

    _ = try store.recordCredentials([original])
    _ = try store.recordCredentials([updated])
    let summary = try store.summary()
    let snapshots = try store.credentialSnapshots()

    #expect(summary.credentialCount == 1)
    #expect(snapshots.count == 1)
    #expect(snapshots[0].urlCount == 2)
}

@Test func stateStoreMigratesV1SnapshotsWithoutIdentifierColumns() throws {
    let path = temporaryStatePath()
    try createV1StateStore(
        path: path,
        sourceID: "item-1",
        vaultID: "Private",
        title: "Example",
        rawFingerprint: "raw-secret-token"
    )
    let store = StateStore(path: path)

    try store.initialize()

    let snapshots = try store.credentialSnapshots()
    let encodedSnapshots = String(data: try JSONEncoder().encode(snapshots), encoding: .utf8) ?? ""
    let rawDatabase = try String(decoding: Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self)
    #expect(try store.schemaVersion() == StateStore.currentSchemaVersion)
    #expect(snapshots.count == 1)
    #expect(!snapshots[0].keyFingerprint.isEmpty)
    #expect(!encodedSnapshots.contains("item-1"))
    #expect(!encodedSnapshots.contains("Private"))
    #expect(!encodedSnapshots.contains("Example"))
    #expect(!encodedSnapshots.contains("raw-secret-token"))
    #expect(!rawDatabase.contains("item-1"))
    #expect(!rawDatabase.contains("Private"))
    #expect(!rawDatabase.contains("Example"))
    #expect(!rawDatabase.contains("raw-secret-token"))
}

@Test func stateStoreRecordsDecisionFileMetadata() throws {
    let store = StateStore(path: temporaryStatePath())
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
    let decisionPath = temporaryDirectory().appendingPathComponent("decisions.json").path
    try writeJSON(PlanDecisionFiles.export(from: plan), path: decisionPath)

    try store.recordDecisionFile(path: decisionPath)

    #expect(try store.summary().decisionFileCount == 1)
}

@Test func stateStoreRecordsReceiptMetadata() throws {
    let store = StateStore(path: temporaryStatePath())
    let plan = SyncPlan(
        direction: .onePasswordToApple,
        truthSource: .onePassword,
        conflictPolicy: .fail,
        actions: [],
        warnings: []
    )
    let receipt = ApplyReceipt(
        operation: .sync,
        backupPath: "/tmp/passsync-test.psbackup",
        direction: plan.direction,
        truthSource: plan.truthSource,
        conflictPolicy: plan.conflictPolicy,
        plan: plan
    )
    let receiptPath = try AuditLog().writeReceipt(receipt, directoryPath: temporaryDirectory().path)

    try store.recordReceipt(path: receiptPath)

    #expect(try store.summary().receiptCount == 1)
}

private func temporaryStatePath() -> String {
    temporaryDirectory().appendingPathComponent("passsync.sqlite").path
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}

private func writeJSON<T: Encodable>(_ value: T, path: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(value).write(to: url, options: [.atomic])
}

private func setSQLiteUserVersion(path: String, version: Int) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK, let db else {
        throw PassSyncError.decodingFailed("Could not open test SQLite database.")
    }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, "PRAGMA user_version = \(version);", nil, nil, nil) == SQLITE_OK else {
        throw PassSyncError.decodingFailed("Could not set test SQLite user_version.")
    }
}

private func createV1StateStore(
    path: String,
    sourceID: String,
    vaultID: String,
    title: String,
    rawFingerprint: String
) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK, let db else {
        throw PassSyncError.decodingFailed("Could not open test SQLite database.")
    }
    defer { sqlite3_close(db) }
    let sql = """
    CREATE TABLE credential_snapshots (
      provider TEXT NOT NULL,
      host TEXT NOT NULL,
      username TEXT NOT NULL,
      source_id TEXT,
      vault_id TEXT,
      title TEXT NOT NULL,
      url_count INTEGER NOT NULL,
      has_totp INTEGER NOT NULL,
      has_passkey INTEGER NOT NULL,
      modified_at TEXT,
      raw_fingerprint TEXT,
      observed_at TEXT NOT NULL,
      PRIMARY KEY(provider, host, username)
    );
    INSERT INTO credential_snapshots (
      provider, host, username, source_id, vault_id, title, url_count, has_totp, has_passkey, modified_at, raw_fingerprint, observed_at
    ) VALUES (
      '1password', 'example.test', 'user@example.test', '\(sourceID)', '\(vaultID)', '\(title)', 1, 1, 0, NULL, '\(rawFingerprint)', '2026-06-13T01:02:03Z'
    );
    PRAGMA user_version = 1;
    """
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
        throw PassSyncError.decodingFailed("Could not create v1 test state store.")
    }
}
