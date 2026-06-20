import Foundation

public struct SyncExecutor<OnePassword: OnePasswordManaging, ApplePasswords: ApplePasswordsManaging>: Sendable {
    private let onePassword: OnePassword
    private let applePasswords: ApplePasswords
    private let allowPasswordOnlyForUnsupportedSecurityMaterial: Bool

    public init(
        onePassword: OnePassword,
        applePasswords: ApplePasswords,
        allowPasswordOnlyForUnsupportedSecurityMaterial: Bool = false
    ) {
        self.onePassword = onePassword
        self.applePasswords = applePasswords
        self.allowPasswordOnlyForUnsupportedSecurityMaterial = allowPasswordOnlyForUnsupportedSecurityMaterial
    }

    public func apply(plan: SyncPlan, onePasswordVault: String? = nil) throws {
        if plan.hasBlockingActions {
            let reasons = plan.actions
                .filter { $0.kind == .conflict || $0.kind == .unsupported }
                .map { "\($0.key): \($0.reason)" }
                .joined(separator: "\n")
            throw PassSyncError.unsafeApply("Plan contains blocking conflict or unsupported actions:\n\(reasons)")
        }

        for action in plan.mutatingActions {
            try validateMutation(action)
            switch action.kind {
            case .createInOnePassword:
                guard let record = action.sourceRecord else { continue }
                try onePassword.create(record.withProvider(.onePassword), vault: onePasswordVault)
            case .createInApple:
                guard let record = action.sourceRecord else { continue }
                try applePasswords.create(record.withProvider(.applePasswords))
            case .updateOnePassword:
                guard let source = action.sourceRecord, let destination = action.destinationRecord else { continue }
                try onePassword.update(source.withProvider(.onePassword), existing: destination, vault: onePasswordVault)
            case .updateApple:
                guard let source = action.sourceRecord, let destination = action.destinationRecord else { continue }
                try applePasswords.update(source.withProvider(.applePasswords), existing: destination)
            case .skipIdentical, .conflict, .unsupported:
                continue
            }
        }
    }

    private func validateMutation(_ action: SyncAction) throws {
        guard let source = action.sourceRecord else { return }
        if source.hasPasskey {
            throw PassSyncError.unsafeApply("Refusing to apply \(action.kind.rawValue) for \(action.key) because the source contains passkey evidence.")
        }
        guard action.destination == .applePasswords else { return }
        if source.totpURI != nil, !allowPasswordOnlyForUnsupportedSecurityMaterial {
            throw PassSyncError.unsafeApply("Refusing to apply \(action.kind.rawValue) for \(action.key) because Apple Passwords cannot receive TOTP material through the Keychain internet-password API.")
        }
    }
}
