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
