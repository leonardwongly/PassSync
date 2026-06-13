import Foundation

public enum RestoreVerificationSeverity: String, Codable, Sendable {
    case pass
    case warning
    case fail
}

public struct RestoreVerificationIssue: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var key: CredentialKey?
    public var severity: RestoreVerificationSeverity
    public var title: String
    public var detail: String
    public var fieldDiffs: [CredentialFieldDiff]

    public init(
        id: String,
        key: CredentialKey?,
        severity: RestoreVerificationSeverity,
        title: String,
        detail: String,
        fieldDiffs: [CredentialFieldDiff] = []
    ) {
        self.id = id
        self.key = key
        self.severity = severity
        self.title = title
        self.detail = detail
        self.fieldDiffs = fieldDiffs
    }
}

public struct RestoreVerificationReport: Codable, Equatable, Sendable {
    public var target: RestoreTarget
    public var checkedAt: Date
    public var issues: [RestoreVerificationIssue]

    public init(target: RestoreTarget, checkedAt: Date = Date(), issues: [RestoreVerificationIssue]) {
        self.target = target
        self.checkedAt = checkedAt
        self.issues = issues
    }

    public var passed: Bool {
        !issues.contains { $0.severity == .fail }
    }

    public var failureCount: Int {
        issues.filter { $0.severity == .fail }.count
    }

    public var warningCount: Int {
        issues.filter { $0.severity == .warning }.count
    }

    public var passCount: Int {
        issues.filter { $0.severity == .pass }.count
    }
}

public struct RestoreVerifier: Sendable {
    public init() {}

    public func verify(
        backup: BackupPayload,
        currentRecords: [CredentialRecord],
        target: RestoreTarget,
        allowPasswordOnlyForUnsupportedSecurityMaterial: Bool = false
    ) -> RestoreVerificationReport {
        let plan = RestorePlanner().buildPlan(
            backup: backup,
            currentRecords: currentRecords,
            target: target,
            allowPasswordOnlyForUnsupportedSecurityMaterial: allowPasswordOnlyForUnsupportedSecurityMaterial
        )
        let issues = plan.actions.enumerated().map { index, action in
            issue(for: action, index: index)
        }
        return RestoreVerificationReport(target: target, issues: issues)
    }

    private func issue(for action: SyncAction, index: Int) -> RestoreVerificationIssue {
        let id = "\(index)-\(action.key.description)-\(action.kind.rawValue)"
        switch action.kind {
        case .skipIdentical:
            if action.sourceRecord == nil {
                return RestoreVerificationIssue(
                    id: id,
                    key: action.key,
                    severity: .warning,
                    title: "Extra current record",
                    detail: "This record exists in the provider now but was not present in the backup."
                )
            }
            return RestoreVerificationIssue(
                id: id,
                key: action.key,
                severity: .pass,
                title: "Matches backup",
                detail: "The current provider record already matches the backup."
            )
        case .createInOnePassword, .createInApple:
            return RestoreVerificationIssue(
                id: id,
                key: action.key,
                severity: .fail,
                title: "Missing from provider",
                detail: "The record exists in the backup but is missing from the current provider."
            )
        case .updateOnePassword, .updateApple:
            return RestoreVerificationIssue(
                id: id,
                key: action.key,
                severity: .fail,
                title: "Differs from backup",
                detail: "The current provider record differs from the backup.",
                fieldDiffs: diffs(for: action)
            )
        case .unsupported:
            return RestoreVerificationIssue(
                id: id,
                key: action.key,
                severity: .fail,
                title: "Unsupported restore material",
                detail: action.reason,
                fieldDiffs: diffs(for: action)
            )
        case .conflict:
            return RestoreVerificationIssue(
                id: id,
                key: action.key,
                severity: .fail,
                title: "Unresolved conflict",
                detail: action.reason,
                fieldDiffs: diffs(for: action)
            )
        }
    }

    private func diffs(for action: SyncAction) -> [CredentialFieldDiff] {
        guard let source = action.sourceRecord,
              let destination = action.destinationRecord else {
            return []
        }
        return CredentialDiff.fieldDiffs(source: source, destination: destination)
    }
}
