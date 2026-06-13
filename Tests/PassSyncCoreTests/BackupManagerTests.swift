import Foundation
import Testing
@testable import PassSyncCore

@Test func encryptedBackupDoesNotContainPlaintextSecretAndCanRestore() throws {
    let record = CredentialRecord(
        provider: .onePassword,
        title: "Example",
        username: "user@example.com",
        password: "plain-secret-password",
        urls: ["https://example.com/login"],
        totpURI: "otpauth://totp/example:user?secret=ABC&issuer=Example"
    )
    let payload = BackupPayload(onePasswordRecords: [record], appleRecords: [], warnings: ["test"])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("backup.psbackup").path

    try BackupManager().writeEncryptedBackup(payload: payload, passphrase: "correct horse battery staple", outputPath: path)
    let encrypted = try String(contentsOfFile: path, encoding: .utf8)

    #expect(!encrypted.contains("plain-secret-password"))
    #expect(!encrypted.contains("secret=ABC"))

    let restored = try BackupManager().readEncryptedBackup(inputPath: path, passphrase: "correct horse battery staple")
    #expect(restored.onePasswordRecords == [record])
}

@Test func encryptedBackupUsesPBKDF2Envelope() throws {
    let payload = BackupPayload(onePasswordRecords: [], appleRecords: [], warnings: [])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("backup.psbackup").path

    try BackupManager().writeEncryptedBackup(payload: payload, passphrase: "correct horse battery staple", outputPath: path)
    let envelope = try JSONDecoder().decode(EncryptedBackupEnvelope.self, from: Data(contentsOf: URL(fileURLWithPath: path)))

    #expect(envelope.format == "passsync.encrypted-backup.v2")
    #expect(envelope.kdf == "pbkdf2-hmac-sha256")
    #expect(envelope.iterations >= 310_000)
}

@Test func backupMigrationRewritesBackupWithCurrentEnvelope() throws {
    let payload = BackupPayload(
        onePasswordRecords: [
            CredentialRecord(
                provider: .onePassword,
                title: "Example",
                username: "user@example.com",
                password: "plain-secret-password",
                urls: ["https://example.com/login"]
            )
        ],
        appleRecords: [],
        warnings: ["test"]
    )
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let inputPath = directory.appendingPathComponent("input.psbackup").path
    let outputPath = directory.appendingPathComponent("output.psbackup").path

    try BackupManager().writeEncryptedBackup(payload: payload, passphrase: "correct horse battery staple", outputPath: inputPath)
    let info = try BackupManager().migrateEncryptedBackup(
        inputPath: inputPath,
        outputPath: outputPath,
        passphrase: "correct horse battery staple"
    )
    let restored = try BackupManager().readEncryptedBackup(inputPath: outputPath, passphrase: "correct horse battery staple")

    #expect(info.format == "passsync.encrypted-backup.v2")
    #expect(info.kdf == "pbkdf2-hmac-sha256")
    #expect(info.iterations >= 310_000)
    #expect(restored.onePasswordRecords == payload.onePasswordRecords)
}

@Test func backupMigrationRefusesSameInputAndOutputPath() throws {
    do {
        _ = try BackupManager().migrateEncryptedBackup(
            inputPath: "/tmp/passsync-same.psbackup",
            outputPath: "/tmp/passsync-same.psbackup",
            passphrase: "correct horse battery staple"
        )
        Issue.record("Expected same-path migration to fail.")
    } catch let error as PassSyncError {
        #expect(error.description.contains("distinct input and output"))
    }
}
