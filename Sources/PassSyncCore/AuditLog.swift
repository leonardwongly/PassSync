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
    public var previousReceiptSHA256: String?

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
        postApplyVerification: PostApplyVerification? = nil,
        previousReceiptSHA256: String? = nil
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
        self.previousReceiptSHA256 = previousReceiptSHA256
    }
}

public struct AuditLog: Sendable {
    public init() {}

    public func writeReceipt(_ receipt: ApplyReceipt, directoryPath: String) throws -> String {
        let directoryURL = URL(fileURLWithPath: directoryPath)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var receipt = receipt
        receipt.previousReceiptSHA256 = try latestReceiptSHA256(in: directoryURL)

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

    private func latestReceiptSHA256(in directoryURL: URL) throws -> String? {
        let files = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let receipts = files
            .filter { $0.lastPathComponent.hasSuffix(".receipt.json") }
            .sorted { $0.path < $1.path }
        guard let latest = receipts.last else { return nil }
        return SHA256Fingerprint.hex(try Data(contentsOf: latest))
    }
}

public struct AuditInventoryItem: Codable, Equatable, Sendable, Identifiable {
    public var path: String
    public var fileSize: UInt64
    public var modifiedAt: Date?
    public var sha256: String?
    public var receipt: ApplyReceipt?
    public var error: String?

    public init(
        path: String,
        fileSize: UInt64,
        modifiedAt: Date?,
        sha256: String?,
        receipt: ApplyReceipt?,
        error: String?
    ) {
        self.path = path
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.sha256 = sha256
        self.receipt = receipt
        self.error = error
    }

    public var id: String { path }
}

public struct AuditInventory: Sendable {
    public init() {}

    public func scan(path: String) -> [AuditInventoryItem] {
        let url = URL(fileURLWithPath: path)
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return [
                AuditInventoryItem(
                    path: url.path,
                    fileSize: 0,
                    modifiedAt: nil,
                    sha256: nil,
                    receipt: nil,
                    error: "Path does not exist."
                )
            ]
        }

        let files: [URL]
        if isDirectory.boolValue {
            files = (try? fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ))?.filter { candidate in
                candidate.lastPathComponent.hasSuffix(".receipt.json")
            } ?? []
        } else {
            files = [url]
        }

        return files
            .sorted { $0.path < $1.path }
            .map(item)
    }

    private func item(for url: URL) -> AuditInventoryItem {
        let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = UInt64(resourceValues?.fileSize ?? 0)
        let modifiedAt = resourceValues?.contentModificationDate
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let receipt = try decoder.decode(ApplyReceipt.self, from: data)
            return AuditInventoryItem(
                path: url.path,
                fileSize: size,
                modifiedAt: modifiedAt,
                sha256: SHA256Fingerprint.hex(data),
                receipt: receipt,
                error: nil
            )
        } catch {
            return AuditInventoryItem(
                path: url.path,
                fileSize: size,
                modifiedAt: modifiedAt,
                sha256: nil,
                receipt: nil,
                error: String(describing: error)
            )
        }
    }
}
