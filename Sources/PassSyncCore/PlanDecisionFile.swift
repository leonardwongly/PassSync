import Foundation

public enum PlanDecisionKind: String, Codable, Sendable, CaseIterable {
    case applyOriginal
    case skip
    case useOnePassword
    case useApplePasswords
    case mergeFields
}

public struct PlanFieldDecision: Codable, Equatable, Sendable, Identifiable {
    public var field: CredentialField
    public var provider: Provider

    public init(field: CredentialField, provider: Provider) {
        self.field = field
        self.provider = provider
    }

    public var id: String { field.rawValue }
}

public struct PlanActionDecision: Codable, Equatable, Sendable, Identifiable {
    public var key: CredentialKey
    public var originalKind: SyncActionKind
    public var decision: PlanDecisionKind
    public var reason: String
    public var fieldDiffs: [CredentialFieldDiff]
    public var fieldDecisions: [PlanFieldDecision]

    public init(
        key: CredentialKey,
        originalKind: SyncActionKind,
        decision: PlanDecisionKind,
        reason: String,
        fieldDiffs: [CredentialFieldDiff] = [],
        fieldDecisions: [PlanFieldDecision] = []
    ) {
        self.key = key
        self.originalKind = originalKind
        self.decision = decision
        self.reason = reason
        self.fieldDiffs = fieldDiffs
        self.fieldDecisions = fieldDecisions
    }

    public var id: String { "\(key.description)-\(originalKind.rawValue)" }
}

public struct PlanDecisionFile: Codable, Equatable, Sendable {
    public var format: String
    public var generatedAt: Date
    public var planGeneratedAt: Date
    public var direction: SyncDirection
    public var truthSource: TruthSource
    public var conflictPolicy: ConflictPolicy
    public var decisions: [PlanActionDecision]

    public init(
        format: String = "passsync.plan-decisions.v1",
        generatedAt: Date = Date(),
        planGeneratedAt: Date,
        direction: SyncDirection,
        truthSource: TruthSource,
        conflictPolicy: ConflictPolicy,
        decisions: [PlanActionDecision]
    ) {
        self.format = format
        self.generatedAt = generatedAt
        self.planGeneratedAt = planGeneratedAt
        self.direction = direction
        self.truthSource = truthSource
        self.conflictPolicy = conflictPolicy
        self.decisions = decisions
    }
}

public enum PlanDecisionFiles {
    public static func export(from plan: SyncPlan) -> PlanDecisionFile {
        PlanDecisionFile(
            planGeneratedAt: plan.generatedAt,
            direction: plan.direction,
            truthSource: plan.truthSource,
            conflictPolicy: plan.conflictPolicy,
            decisions: plan.actions.map(decision)
        )
    }

    public static func apply(
        _ decisionFile: PlanDecisionFile,
        to plan: SyncPlan,
        allowPasswordOnlyForUnsupportedSecurityMaterial: Bool = false
    ) -> SyncPlan {
        let decisions = Dictionary(uniqueKeysWithValues: decisionFile.decisions.map { ($0.id, $0) })
        var resolvedActions: [SyncAction] = []

        for action in plan.actions {
            guard let decision = decisions[actionID(for: action)] else {
                resolvedActions.append(action)
                continue
            }
            resolvedActions.append(contentsOf: apply(decision, to: action, allowPasswordOnlyForUnsupportedSecurityMaterial: allowPasswordOnlyForUnsupportedSecurityMaterial))
        }

        var copy = plan
        copy.actions = resolvedActions
        copy.warnings.append("Plan decisions loaded from \(decisionFile.format). Re-review this plan before applying if provider state changed.")
        return copy
    }

    private static func decision(for action: SyncAction) -> PlanActionDecision {
        let diffs = redactedDiffs(for: action)
        let kind: PlanDecisionKind
        switch action.kind {
        case .conflict:
            kind = .skip
        case .unsupported:
            kind = .skip
        case .createInOnePassword, .createInApple, .updateOnePassword, .updateApple, .skipIdentical:
            kind = .applyOriginal
        }
        return PlanActionDecision(
            key: action.key,
            originalKind: action.kind,
            decision: kind,
            reason: action.reason,
            fieldDiffs: diffs,
            fieldDecisions: defaultFieldDecisions(for: action, diffs: diffs)
        )
    }

    private static func apply(
        _ decision: PlanActionDecision,
        to action: SyncAction,
        allowPasswordOnlyForUnsupportedSecurityMaterial: Bool
    ) -> [SyncAction] {
        switch decision.decision {
        case .applyOriginal:
            return [action]
        case .skip:
            return [
                SyncAction(
                    kind: .skipIdentical,
                    key: action.key,
                    source: action.source,
                    destination: action.destination,
                    reason: "Skipped by reviewed decision file.",
                    sourceRecord: action.sourceRecord,
                    destinationRecord: action.destinationRecord
                )
            ]
        case .useOnePassword:
            return chooseProvider(.onePassword, for: action, allowPasswordOnlyForUnsupportedSecurityMaterial: allowPasswordOnlyForUnsupportedSecurityMaterial)
        case .useApplePasswords:
            return chooseProvider(.applePasswords, for: action, allowPasswordOnlyForUnsupportedSecurityMaterial: allowPasswordOnlyForUnsupportedSecurityMaterial)
        case .mergeFields:
            return mergeFields(decision.fieldDecisions, for: action, allowPasswordOnlyForUnsupportedSecurityMaterial: allowPasswordOnlyForUnsupportedSecurityMaterial)
        }
    }

    private static func chooseProvider(
        _ provider: Provider,
        for action: SyncAction,
        allowPasswordOnlyForUnsupportedSecurityMaterial: Bool
    ) -> [SyncAction] {
        guard let source = record(provider: provider, action: action),
              let destination = record(provider: opposite(provider), action: action) else {
            return [blocking(action, reason: "Decision selected \(provider.rawValue), but both provider records are required.")]
        }
        guard let action = updateAction(
            source: source,
            destination: destination,
            key: action.key,
            reason: "Reviewed decision selected \(provider.rawValue).",
            allowPasswordOnlyForUnsupportedSecurityMaterial: allowPasswordOnlyForUnsupportedSecurityMaterial
        ) else {
            return [blocking(action, reason: "Reviewed decision would transfer unsupported passkey or TOTP material.")]
        }
        return [action]
    }

    private static func mergeFields(
        _ fieldDecisions: [PlanFieldDecision],
        for action: SyncAction,
        allowPasswordOnlyForUnsupportedSecurityMaterial: Bool
    ) -> [SyncAction] {
        guard let onePassword = record(provider: .onePassword, action: action),
              let apple = record(provider: .applePasswords, action: action) else {
            return [blocking(action, reason: "Field merge requires records from both providers.")]
        }

        let choices = Dictionary(uniqueKeysWithValues: fieldDecisions.map { ($0.field, $0.provider) })
        let diffs = CredentialDiff.fieldDiffs(source: onePassword, destination: apple)
        let missing = diffs
            .map(\.field)
            .filter { $0 != .modifiedAt }
            .filter { choices[$0] == nil }
        guard missing.isEmpty else {
            return [blocking(action, reason: "Field merge is missing choices for: \(missing.map(\.rawValue).joined(separator: ", ")).")]
        }

        var merged = onePassword
        for field in CredentialField.allCases {
            let provider = choices[field] ?? .onePassword
            let selected = provider == .onePassword ? onePassword : apple
            apply(field: field, from: selected, to: &merged)
        }

        var actions: [SyncAction] = []
        if !recordsEquivalent(merged, onePassword) {
            guard let update = updateAction(
                source: merged.withProvider(.onePassword),
                destination: onePassword,
                key: action.key,
                reason: "Reviewed field-level merge.",
                allowPasswordOnlyForUnsupportedSecurityMaterial: allowPasswordOnlyForUnsupportedSecurityMaterial
            ) else {
                return [blocking(action, reason: "Field merge would write unsupported material to 1Password.")]
            }
            actions.append(update)
        }
        if !recordsEquivalent(merged, apple) {
            guard let update = updateAction(
                source: merged.withProvider(.applePasswords),
                destination: apple,
                key: action.key,
                reason: "Reviewed field-level merge.",
                allowPasswordOnlyForUnsupportedSecurityMaterial: allowPasswordOnlyForUnsupportedSecurityMaterial
            ) else {
                return [blocking(action, reason: "Field merge would write unsupported material to Apple Passwords.")]
            }
            actions.append(update)
        }
        if actions.isEmpty {
            actions.append(SyncAction(
                kind: .skipIdentical,
                key: action.key,
                source: action.source,
                destination: action.destination,
                reason: "Reviewed field-level merge already matches both providers.",
                sourceRecord: onePassword,
                destinationRecord: apple
            ))
        }
        return actions
    }

    private static func updateAction(
        source: CredentialRecord,
        destination: CredentialRecord,
        key: CredentialKey,
        reason: String,
        allowPasswordOnlyForUnsupportedSecurityMaterial: Bool
    ) -> SyncAction? {
        if source.hasPasskey {
            return nil
        }
        if destination.provider == .applePasswords, source.totpURI != nil, !allowPasswordOnlyForUnsupportedSecurityMaterial {
            return nil
        }
        return SyncAction(
            kind: destination.provider == .onePassword ? .updateOnePassword : .updateApple,
            key: key,
            source: source.provider,
            destination: destination.provider,
            reason: reason,
            sourceRecord: source,
            destinationRecord: destination
        )
    }

    private static func blocking(_ action: SyncAction, reason: String) -> SyncAction {
        SyncAction(
            kind: .unsupported,
            key: action.key,
            source: action.source,
            destination: action.destination,
            reason: reason,
            sourceRecord: action.sourceRecord,
            destinationRecord: action.destinationRecord
        )
    }

    private static func defaultFieldDecisions(for action: SyncAction, diffs: [CredentialFieldDiff]) -> [PlanFieldDecision] {
        guard action.kind == .conflict || action.kind == .updateOnePassword || action.kind == .updateApple else {
            return []
        }
        return diffs
            .filter { $0.field != .modifiedAt }
            .map { PlanFieldDecision(field: $0.field, provider: action.source ?? .onePassword) }
    }

    private static func redactedDiffs(for action: SyncAction) -> [CredentialFieldDiff] {
        guard let source = action.sourceRecord,
              let destination = action.destinationRecord else {
            return []
        }
        return CredentialDiff.fieldDiffs(source: source, destination: destination)
    }

    private static func record(provider: Provider, action: SyncAction) -> CredentialRecord? {
        if action.sourceRecord?.provider == provider {
            return action.sourceRecord
        }
        if action.destinationRecord?.provider == provider {
            return action.destinationRecord
        }
        return nil
    }

    private static func opposite(_ provider: Provider) -> Provider {
        provider == .onePassword ? .applePasswords : .onePassword
    }

    private static func actionID(for action: SyncAction) -> String {
        "\(action.key.description)-\(action.kind.rawValue)"
    }

    private static func apply(field: CredentialField, from source: CredentialRecord, to destination: inout CredentialRecord) {
        switch field {
        case .title:
            destination.title = source.title
        case .username:
            destination.username = source.username
        case .password:
            destination.password = source.password
        case .urls:
            destination.urls = source.urls
        case .notes:
            destination.notes = source.notes
        case .totpURI:
            destination.totpURI = source.totpURI
        case .hasPasskey:
            destination.hasPasskey = source.hasPasskey
        case .modifiedAt:
            destination.modifiedAt = source.modifiedAt
        }
    }

    private static func recordsEquivalent(_ lhs: CredentialRecord, _ rhs: CredentialRecord) -> Bool {
        lhs.title == rhs.title &&
            lhs.username == rhs.username &&
            lhs.password == rhs.password &&
            lhs.urls == rhs.urls &&
            lhs.notes == rhs.notes &&
            lhs.totpURI == rhs.totpURI &&
            lhs.hasPasskey == rhs.hasPasskey
    }
}
