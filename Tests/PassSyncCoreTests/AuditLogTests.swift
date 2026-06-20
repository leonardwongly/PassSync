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

@Test func auditInventoryDecodesReceiptAndComputesFileHash() throws {
    let plan = SyncPlan(
        direction: .appleToOnePassword,
        truthSource: .applePasswords,
        conflictPolicy: .fail,
        actions: [],
        warnings: []
    )
    let receipt = ApplyReceipt(
        operation: .restore,
        backupPath: "/tmp/passsync-test.psbackup",
        direction: plan.direction,
        truthSource: plan.truthSource,
        conflictPolicy: plan.conflictPolicy,
        restoreTarget: .onePassword,
        plan: plan
    )
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let path = try AuditLog().writeReceipt(receipt, directoryPath: directory.path)
    let expectedHash = SHA256Fingerprint.hex(try Data(contentsOf: URL(fileURLWithPath: path)))

    let items = AuditInventory().scan(path: directory.path)

    #expect(items.count == 1)
    #expect(items[0].sha256 == expectedHash)
    #expect(items[0].receipt?.operation == .restore)
    #expect(items[0].receipt?.restoreTarget == .onePassword)
    #expect(items[0].error == nil)
}

@Test func auditLogCreatesPrivateDirectoryAndReceipt() throws {
    let plan = SyncPlan(
        direction: .appleToOnePassword,
        truthSource: .applePasswords,
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
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    let path = try AuditLog().writeReceipt(receipt, directoryPath: directory.path)

    #expect(try SecureFileIO.permissions(at: directory.path) == 0o700)
    #expect(try SecureFileIO.permissions(at: path) == 0o600)
}

@Test func auditLogChainsReceiptsWithPreviousReceiptHash() throws {
    let firstDate = try #require(ISO8601DateFormatter().date(from: "2026-06-13T01:00:00Z"))
    let secondDate = try #require(ISO8601DateFormatter().date(from: "2026-06-13T01:01:00Z"))
    let plan = SyncPlan(
        direction: .bidirectional,
        truthSource: .none,
        conflictPolicy: .fail,
        actions: [],
        warnings: []
    )
    let first = ApplyReceipt(
        createdAt: firstDate,
        operation: .sync,
        backupPath: "/tmp/passsync-first.psbackup",
        direction: plan.direction,
        truthSource: plan.truthSource,
        conflictPolicy: plan.conflictPolicy,
        plan: plan
    )
    let second = ApplyReceipt(
        createdAt: secondDate,
        operation: .restore,
        backupPath: "/tmp/passsync-second.psbackup",
        direction: plan.direction,
        truthSource: plan.truthSource,
        conflictPolicy: plan.conflictPolicy,
        restoreTarget: .onePassword,
        plan: plan
    )
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    let firstPath = try AuditLog().writeReceipt(first, directoryPath: directory.path)
    let secondPath = try AuditLog().writeReceipt(second, directoryPath: directory.path)
    let firstHash = SHA256Fingerprint.hex(try Data(contentsOf: URL(fileURLWithPath: firstPath)))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decodedFirst = try decoder.decode(ApplyReceipt.self, from: Data(contentsOf: URL(fileURLWithPath: firstPath)))
    let decodedSecond = try decoder.decode(ApplyReceipt.self, from: Data(contentsOf: URL(fileURLWithPath: secondPath)))

    #expect(decodedFirst.previousReceiptSHA256 == nil)
    #expect(decodedSecond.previousReceiptSHA256 == firstHash)
}

@Test func auditChainVerifierPassesIntactReceiptChain() throws {
    let directory = try writeTwoReceiptChain()

    let report = AuditChainVerifier().verify(path: directory.path)

    #expect(report.receiptCount == 2)
    #expect(!report.hasFailures)
    #expect(report.issues.map(\.severity) == [.pass, .pass])
}

@Test func auditChainVerifierFailsWhenPriorReceiptChanges() throws {
    let directory = try writeTwoReceiptChain()
    let firstReceipt = try #require(
        FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.contains("passsync-sync-") }
    )
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var receipt = try decoder.decode(ApplyReceipt.self, from: Data(contentsOf: firstReceipt))
    receipt.backupPath = "/tmp/tampered.psbackup"
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(receipt).write(to: firstReceipt, options: [.atomic])

    let report = AuditChainVerifier().verify(path: directory.path)

    #expect(report.hasFailures)
    #expect(report.failureCount == 1)
    #expect(report.issues.contains { $0.title == "Receipt chain link mismatch" })
}

@Test func auditChainVerifierFailsMalformedReceiptFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("{ not json".utf8).write(to: directory.appendingPathComponent("bad.receipt.json"))

    let report = AuditChainVerifier().verify(path: directory.path)

    #expect(report.hasFailures)
    #expect(report.failureCount == 1)
    #expect(report.issues[0].title == "Receipt could not be decoded")
}

@Test func auditInventoryReportsMissingPath() {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    let items = AuditInventory().scan(path: missing.path)

    #expect(items.count == 1)
    #expect(items[0].error == "Path does not exist.")
}

private func writeTwoReceiptChain() throws -> URL {
    let firstDate = try #require(ISO8601DateFormatter().date(from: "2026-06-13T01:00:00Z"))
    let secondDate = try #require(ISO8601DateFormatter().date(from: "2026-06-13T01:01:00Z"))
    let plan = SyncPlan(
        direction: .bidirectional,
        truthSource: .none,
        conflictPolicy: .fail,
        actions: [],
        warnings: []
    )
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    _ = try AuditLog().writeReceipt(
        ApplyReceipt(
            createdAt: firstDate,
            operation: .sync,
            backupPath: "/tmp/passsync-first.psbackup",
            direction: plan.direction,
            truthSource: plan.truthSource,
            conflictPolicy: plan.conflictPolicy,
            plan: plan
        ),
        directoryPath: directory.path
    )
    _ = try AuditLog().writeReceipt(
        ApplyReceipt(
            createdAt: secondDate,
            operation: .restore,
            backupPath: "/tmp/passsync-second.psbackup",
            direction: plan.direction,
            truthSource: plan.truthSource,
            conflictPolicy: plan.conflictPolicy,
            restoreTarget: .onePassword,
            plan: plan
        ),
        directoryPath: directory.path
    )
    return directory
}
