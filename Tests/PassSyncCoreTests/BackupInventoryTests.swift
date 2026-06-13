import Foundation
import Testing
@testable import PassSyncCore

@Test func backupInventoryInspectsEncryptedBackupEnvelopeWithoutPassphrase() throws {
    let payload = BackupPayload(onePasswordRecords: [], appleRecords: [], warnings: [])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("inventory.psbackup").path
    try BackupManager().writeEncryptedBackup(payload: payload, passphrase: "correct horse battery staple", outputPath: path)

    let items = BackupInventory().scan(path: directory.path)

    #expect(items.count == 1)
    #expect(URL(fileURLWithPath: items[0].path).standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path)
    #expect(items[0].envelope?.format == "passsync.encrypted-backup.v2")
    #expect(items[0].envelope?.kdf == "pbkdf2-hmac-sha256")
    #expect(items[0].error == nil)
}

@Test func backupInventoryReportsMissingPath() {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    let items = BackupInventory().scan(path: missing.path)

    #expect(items.count == 1)
    #expect(items[0].error == "Path does not exist.")
}
