import Foundation

public struct SyncExecutor<OnePassword: OnePasswordManaging, ApplePasswords: ApplePasswordsManaging>: Sendable {
    private let onePassword: OnePassword
    private let applePasswords: ApplePasswords

    public init(onePassword: OnePassword, applePasswords: ApplePasswords) {
        self.onePassword = onePassword
        self.applePasswords = applePasswords
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
}
