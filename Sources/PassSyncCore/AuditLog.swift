import Foundation

public enum ApplyOperation: String, Codable, Sendable {
    case sync
    case restore
}

public struct PlanActionReceipt: Codable, Equatable, Sendable, Identifiable {
    public var key: CredentialKey
    public var kind: SyncActionKind
    public var source: Provider?
    public var destination: Provider?
    public var reason: String

    public init(action: SyncAction) {
        self.key = action.key
        self.kind = action.kind
        self.source = action.source
        self.destination = action.destination
        self.reason = action.reason
    }

    public var id: String { "\(key.description)-\(kind.rawValue)" }
}

public struct PostApplyVerification: Codable, Equatable, Sendable {
    public var checkedAt: Date
    public var mutatingActionCount: Int
    public var blockingActionCount: Int
    public var warningCount: Int
    public var notes: [String]

    public init(
        checkedAt: Date = Date(),
        mutatingActionCount: Int,
        blockingActionCount: Int,
        warningCount: Int,
        notes: [String]
    ) {
        self.checkedAt = checkedAt
        self.mutatingActionCount = mutatingActionCount
        self.blockingActionCount = blockingActionCount
        self.warningCount = warningCount
        self.notes = notes
    }
}

public struct ApplyReceipt: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var operation: ApplyOperation
    public var backupPath: String
    public var safetyBackupPath: String?
    public var decisionFilePath: String?
    public var direction: SyncDirection
    public var truthSource: TruthSource
    public var conflictPolicy: ConflictPolicy
    public var restoreTarget: RestoreTarget?
    public var actionCount: Int
    public var mutatingActionCount: Int
    public var actions: [PlanActionReceipt]
    public var postApplyVerification: PostApplyVerification?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        operation: ApplyOperation,
        backupPath: String,
        safetyBackupPath: String? = nil,
        decisionFilePath: String? = nil,
        direction: SyncDirection,
        truthSource: TruthSource,
        conflictPolicy: ConflictPolicy,
        restoreTarget: RestoreTarget? = nil,
        plan: SyncPlan,
        postApplyVerification: PostApplyVerification? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.operation = operation
        self.backupPath = backupPath
        self.safetyBackupPath = safetyBackupPath
        self.decisionFilePath = decisionFilePath
        self.direction = direction
        self.truthSource = truthSource
        self.conflictPolicy = conflictPolicy
        self.restoreTarget = restoreTarget
        self.actionCount = plan.actions.count
        self.mutatingActionCount = plan.mutatingActions.count
        self.actions = plan.actions.map(PlanActionReceipt.init)
        self.postApplyVerification = postApplyVerification
    }
}

public struct AuditLog: Sendable {
    public init() {}

    public func writeReceipt(_ receipt: ApplyReceipt, directoryPath: String) throws -> String {
        let directoryURL = URL(fileURLWithPath: directoryPath)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let stamp = formatter.string(from: receipt.createdAt).replacingOccurrences(of: ":", with: "")
        let path = directoryURL.appendingPathComponent("passsync-\(receipt.operation.rawValue)-\(stamp)-\(receipt.id.uuidString).receipt.json").path

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(receipt).write(to: URL(fileURLWithPath: path), options: [.atomic])
        return path
    }
}
