import Foundation
import Testing
@testable import PassSyncCore

@Test func auditLogWritesReceiptWithoutSecrets() throws {
    let record = CredentialRecord(
        provider: .onePassword,
        title: "Example",
        username: "user@example.test",
        password: "plain-secret",
        urls: ["https://example.test/login"]
    )
    let plan = SyncPlan(
        direction: .onePasswordToApple,
        truthSource: .onePassword,
        conflictPolicy: .fail,
        actions: [
            SyncAction(
                kind: .createInApple,
                key: CredentialKey(host: "example.test", username: "user@example.test"),
                source: .onePassword,
                destination: .applePasswords,
                reason: "Destination is missing.",
                sourceRecord: record
            )
        ],
        warnings: []
    )
    let receipt = ApplyReceipt(
        operation: .sync,
        backupPath: "/tmp/passsync-test.psbackup",
        direction: plan.direction,
        truthSource: plan.truthSource,
        conflictPolicy: plan.conflictPolicy,
        plan: plan,
        postApplyVerification: PostApplyVerification(
            mutatingActionCount: 0,
            blockingActionCount: 0,
            warningCount: 0,
            notes: ["test"]
        )
    )
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    let path = try AuditLog().writeReceipt(receipt, directoryPath: directory.path)
    let contents = try String(contentsOfFile: path, encoding: .utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(ApplyReceipt.self, from: Data(contentsOf: URL(fileURLWithPath: path)))

    #expect(!contents.contains("plain-secret"))
    #expect(decoded.operation == .sync)
    #expect(decoded.mutatingActionCount == 1)
}
