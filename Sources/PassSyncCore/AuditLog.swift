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
        try SecureFileIO.createPrivateDirectory(at: directoryURL)
        var receipt = receipt
        receipt.previousReceiptSHA256 = try latestReceiptSHA256(in: directoryURL)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let stamp = formatter.string(from: receipt.createdAt).replacingOccurrences(of: ":", with: "")
        let path = directoryURL.appendingPathComponent("passsync-\(receipt.operation.rawValue)-\(stamp)-\(receipt.id.uuidString).receipt.json").path

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try SecureFileIO.writePrivateData(try encoder.encode(receipt), to: URL(fileURLWithPath: path), overwrite: false)
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
            .sorted(by: receiptFileSort)
        guard let latest = receipts.last else { return nil }
        return SHA256Fingerprint.hex(try Data(contentsOf: latest))
    }

    private func receiptFileSort(_ left: URL, _ right: URL) -> Bool {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let leftReceipt = try? decoder.decode(ApplyReceipt.self, from: Data(contentsOf: left))
        let rightReceipt = try? decoder.decode(ApplyReceipt.self, from: Data(contentsOf: right))
        switch (leftReceipt?.createdAt, rightReceipt?.createdAt) {
        case let (leftDate?, rightDate?):
            return leftDate == rightDate ? left.path < right.path : leftDate < rightDate
        case (_?, nil):
            return false
        case (nil, _?):
            return true
        case (nil, nil):
            return left.path < right.path
        }
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

public struct AuditChainIssue: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var path: String?
    public var severity: DoctorSeverity
    public var title: String
    public var detail: String

    public init(id: String, path: String?, severity: DoctorSeverity, title: String, detail: String) {
        self.id = id
        self.path = path
        self.severity = severity
        self.title = title
        self.detail = detail
    }
}

public struct AuditChainReport: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var path: String
    public var receiptCount: Int
    public var issues: [AuditChainIssue]

    public init(generatedAt: Date = Date(), path: String, receiptCount: Int, issues: [AuditChainIssue]) {
        self.generatedAt = generatedAt
        self.path = path
        self.receiptCount = receiptCount
        self.issues = issues
    }

    public var hasFailures: Bool {
        issues.contains { $0.severity == .fail }
    }

    public var failureCount: Int {
        issues.filter { $0.severity == .fail }.count
    }
}

public struct AuditChainVerifier: Sendable {
    public init() {}

    public func verify(path: String) -> AuditChainReport {
        let items = AuditInventory().scan(path: path).sorted(by: receiptItemSort)
        var issues: [AuditChainIssue] = []
        var previousHash: String?
        var verifiedReceipts = 0

        for item in items {
            guard item.error == nil, let receipt = item.receipt, let sha256 = item.sha256 else {
                issues.append(AuditChainIssue(
                    id: "receipt.decode.\(item.path)",
                    path: item.path,
                    severity: .fail,
                    title: "Receipt could not be decoded",
                    detail: item.error ?? "Missing receipt hash or decoded receipt."
                ))
                continue
            }

            verifiedReceipts += 1
            if let previousHash {
                if receipt.previousReceiptSHA256 == previousHash {
                    issues.append(AuditChainIssue(
                        id: "receipt.chain.\(item.path)",
                        path: item.path,
                        severity: .pass,
                        title: "Receipt chain link matches",
                        detail: "Previous receipt hash matches \(previousHash)."
                    ))
                } else {
                    issues.append(AuditChainIssue(
                        id: "receipt.chain.\(item.path)",
                        path: item.path,
                        severity: .fail,
                        title: "Receipt chain link mismatch",
                        detail: "Expected previous receipt hash \(previousHash), found \(receipt.previousReceiptSHA256 ?? "none")."
                    ))
                }
            } else if let declaredPrevious = receipt.previousReceiptSHA256 {
                issues.append(AuditChainIssue(
                    id: "receipt.chain.first.\(item.path)",
                    path: item.path,
                    severity: .fail,
                    title: "First receipt points to a missing predecessor",
                    detail: "First scanned receipt declares previous hash \(declaredPrevious). Verify the full audit directory."
                ))
            } else {
                issues.append(AuditChainIssue(
                    id: "receipt.chain.first.\(item.path)",
                    path: item.path,
                    severity: .pass,
                    title: "Receipt chain starts here",
                    detail: "First scanned receipt has no previous receipt hash."
                ))
            }

            previousHash = sha256
        }

        if items.isEmpty {
            issues.append(AuditChainIssue(
                id: "receipt.chain.empty",
                path: nil,
                severity: .warning,
                title: "No receipts found",
                detail: "No .receipt.json files were available to verify."
            ))
        }

        return AuditChainReport(path: path, receiptCount: verifiedReceipts, issues: issues)
    }

    private func receiptItemSort(_ left: AuditInventoryItem, _ right: AuditInventoryItem) -> Bool {
        switch (left.receipt?.createdAt, right.receipt?.createdAt) {
        case let (leftDate?, rightDate?):
            return leftDate == rightDate ? left.path < right.path : leftDate < rightDate
        case (_?, nil):
            return false
        case (nil, _?):
            return true
        case (nil, nil):
            return left.path < right.path
        }
    }
}
