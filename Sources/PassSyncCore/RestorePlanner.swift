import Foundation

public struct RestorePlanner: Sendable {
    public init() {}

    public func buildPlan(
        backup: BackupPayload,
        currentRecords: [CredentialRecord],
        target: RestoreTarget,
        allowPasswordOnlyForUnsupportedSecurityMaterial: Bool = false
    ) -> SyncPlan {
        let sourceRecords = records(from: backup, target: target).map { $0.withProvider(target.provider) }
        let sourceByKey = Dictionary(grouping: sourceRecords.compactMap(keyed), by: \.key)
        let currentByKey = Dictionary(grouping: currentRecords.compactMap(keyed), by: \.key)
        let keys = Set(sourceByKey.keys).union(currentByKey.keys).sorted { $0.description < $1.description }

        var actions: [SyncAction] = []
        var warnings: [String] = backup.warnings

        for key in keys {
            let source = chooseRepresentative(sourceByKey[key])
            let current = chooseRepresentative(currentByKey[key])

            guard let source else {
                actions.append(SyncAction(kind: .skipIdentical, key: key, source: nil, destination: target.provider, reason: "Record exists now but was not present in the backup.", destinationRecord: current))
                continue
            }

            if source.hasPasskey {
                warnings.append("Backup record \(key) contains passkey evidence. Provider-managed passkey private key material was not included in the backup.")
                actions.append(SyncAction(kind: .unsupported, key: key, source: target.provider, destination: target.provider, reason: "Backup contains passkey evidence but does not contain migratable passkey private key material.", sourceRecord: source, destinationRecord: current))
                continue
            }

            if target == .applePasswords, source.totpURI != nil, !allowPasswordOnlyForUnsupportedSecurityMaterial {
                actions.append(SyncAction(kind: .unsupported, key: key, source: target.provider, destination: target.provider, reason: "Restoring this Apple Passwords record would drop a TOTP secret; use explicit password-only mode to allow that.", sourceRecord: source, destinationRecord: current))
                continue
            }

            guard let current else {
                actions.append(SyncAction(kind: target == .onePassword ? .createInOnePassword : .createInApple, key: key, source: target.provider, destination: target.provider, reason: "Record exists in backup but is missing from current provider.", sourceRecord: source))
                continue
            }

            if equivalent(source, current) {
                actions.append(SyncAction(kind: .skipIdentical, key: key, source: target.provider, destination: target.provider, reason: "Current provider already matches backup.", sourceRecord: source, destinationRecord: current))
            } else {
                actions.append(SyncAction(kind: target == .onePassword ? .updateOnePassword : .updateApple, key: key, source: target.provider, destination: target.provider, reason: "Current provider differs from backup.", sourceRecord: source, destinationRecord: current))
            }
        }

        return SyncPlan(
            direction: target == .onePassword ? .appleToOnePassword : .onePasswordToApple,
            truthSource: target == .onePassword ? .onePassword : .applePasswords,
            conflictPolicy: .fail,
            actions: actions,
            warnings: warnings
        )
    }

    private func records(from backup: BackupPayload, target: RestoreTarget) -> [CredentialRecord] {
        switch target {
        case .onePassword:
            return backup.onePasswordRecords
        case .applePasswords:
            return backup.appleRecords
        }
    }

    private func keyed(_ record: CredentialRecord) -> (key: CredentialKey, record: CredentialRecord)? {
        guard let key = URLUtilities.key(for: record), !record.username.isEmpty else { return nil }
        return (key, record)
    }

    private func chooseRepresentative(_ records: [(key: CredentialKey, record: CredentialRecord)]?) -> CredentialRecord? {
        records?
            .map(\.record)
            .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
            .first
    }

    private func equivalent(_ lhs: CredentialRecord, _ rhs: CredentialRecord) -> Bool {
        lhs.username == rhs.username &&
            lhs.password == rhs.password &&
            Set(lhs.urls.map { URLUtilities.canonicalHost(from: $0) ?? $0.lowercased() }) == Set(rhs.urls.map { URLUtilities.canonicalHost(from: $0) ?? $0.lowercased() }) &&
            normalized(lhs.notes) == normalized(rhs.notes) &&
            normalized(lhs.totpURI) == normalized(rhs.totpURI)
    }

    private func normalized(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
