import Foundation

public struct SyncPlanner: Sendable {
    public init() {}

    public func buildPlan(
        onePasswordRecords: [CredentialRecord],
        appleRecords: [CredentialRecord],
        options: SyncOptions
    ) -> SyncPlan {
        let onePassword = Dictionary(grouping: onePasswordRecords.compactMap(keyed), by: \.key)
        let apple = Dictionary(grouping: appleRecords.compactMap(keyed), by: \.key)

        var actions: [SyncAction] = []
        var warnings: [String] = []
        let allKeys = Set(onePassword.keys).union(apple.keys).sorted { $0.description < $1.description }

        for key in allKeys {
            let oneP = chooseRepresentative(onePassword[key])
            let appleP = chooseRepresentative(apple[key])

            if let oneP, oneP.hasPasskey {
                warnings.append("1Password item \(key) contains passkey evidence. PassSync will not edit or recreate it through JSON/template paths.")
            }
            if let appleP, appleP.hasPasskey {
                warnings.append("Apple Passwords item \(key) contains passkey evidence. PassSync cannot export or import this passkey through Keychain password APIs.")
            }

            switch options.direction {
            case .onePasswordToApple:
                planOneWay(source: oneP, destination: appleP, key: key, sourceProvider: .onePassword, destinationProvider: .applePasswords, options: options, actions: &actions)
            case .appleToOnePassword:
                planOneWay(source: appleP, destination: oneP, key: key, sourceProvider: .applePasswords, destinationProvider: .onePassword, options: options, actions: &actions)
            case .bidirectional:
                planBidirectional(onePassword: oneP, apple: appleP, key: key, options: options, actions: &actions)
            }
        }

        return SyncPlan(
            direction: options.direction,
            truthSource: options.truthSource,
            conflictPolicy: options.conflictPolicy,
            actions: actions,
            warnings: warnings
        )
    }

    private func keyed(_ record: CredentialRecord) -> (key: CredentialKey, record: CredentialRecord)? {
        guard let key = URLUtilities.key(for: record), !record.username.isEmpty else { return nil }
        return (key, record)
    }

    private func chooseRepresentative(_ records: [(key: CredentialKey, record: CredentialRecord)]?) -> CredentialRecord? {
        records?
            .map(\.record)
            .sorted {
                ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast)
            }
            .first
    }

    private func planOneWay(
        source: CredentialRecord?,
        destination: CredentialRecord?,
        key: CredentialKey,
        sourceProvider: Provider,
        destinationProvider: Provider,
        options: SyncOptions,
        actions: inout [SyncAction]
    ) {
        guard let source else {
            actions.append(SyncAction(kind: .skipIdentical, key: key, source: nil, destination: destinationProvider, reason: "No source record in \(sourceProvider.rawValue).", destinationRecord: destination))
            return
        }

        if let unsupported = unsupportedReason(source: source, destination: destinationProvider, isUpdate: destination != nil, options: options) {
            actions.append(SyncAction(kind: .unsupported, key: key, source: sourceProvider, destination: destinationProvider, reason: unsupported, sourceRecord: source, destinationRecord: destination))
            return
        }

        guard let destination else {
            actions.append(SyncAction(
                kind: destinationProvider == .onePassword ? .createInOnePassword : .createInApple,
                key: key,
                source: sourceProvider,
                destination: destinationProvider,
                reason: "Destination is missing.",
                sourceRecord: source
            ))
            return
        }

        if equivalent(source, destination) {
            actions.append(SyncAction(kind: .skipIdentical, key: key, source: sourceProvider, destination: destinationProvider, reason: "Records are equivalent.", sourceRecord: source, destinationRecord: destination))
            return
        }

        let resolved = resolveConflict(onePassword: sourceProvider == .onePassword ? source : destination, apple: sourceProvider == .applePasswords ? source : destination, key: key, options: options)
        if let resolved, resolved == sourceProvider {
            actions.append(SyncAction(
                kind: destinationProvider == .onePassword ? .updateOnePassword : .updateApple,
                key: key,
                source: sourceProvider,
                destination: destinationProvider,
                reason: "Conflict resolved by \(sourceProvider.rawValue).",
                sourceRecord: source,
                destinationRecord: destination
            ))
        } else if resolved == destinationProvider {
            actions.append(SyncAction(kind: .skipIdentical, key: key, source: sourceProvider, destination: destinationProvider, reason: "Conflict resolved by existing destination.", sourceRecord: source, destinationRecord: destination))
        } else {
            actions.append(SyncAction(kind: .conflict, key: key, source: sourceProvider, destination: destinationProvider, reason: "Records differ and require an interactive decision.", sourceRecord: source, destinationRecord: destination))
        }
    }

    private func planBidirectional(
        onePassword: CredentialRecord?,
        apple: CredentialRecord?,
        key: CredentialKey,
        options: SyncOptions,
        actions: inout [SyncAction]
    ) {
        switch (onePassword, apple) {
        case (.some(let oneP), .none):
            planOneWay(source: oneP, destination: nil, key: key, sourceProvider: .onePassword, destinationProvider: .applePasswords, options: options, actions: &actions)
        case (.none, .some(let appleP)):
            planOneWay(source: appleP, destination: nil, key: key, sourceProvider: .applePasswords, destinationProvider: .onePassword, options: options, actions: &actions)
        case (.some(let oneP), .some(let appleP)):
            if equivalent(oneP, appleP) {
                actions.append(SyncAction(kind: .skipIdentical, key: key, source: .onePassword, destination: .applePasswords, reason: "Records are equivalent.", sourceRecord: oneP, destinationRecord: appleP))
                return
            }
            guard let winner = resolveConflict(onePassword: oneP, apple: appleP, key: key, options: options) else {
                actions.append(SyncAction(kind: .conflict, key: key, source: .onePassword, destination: .applePasswords, reason: "Records differ and require an interactive decision.", sourceRecord: oneP, destinationRecord: appleP))
                return
            }
            if winner == .onePassword {
                planOneWay(source: oneP, destination: appleP, key: key, sourceProvider: .onePassword, destinationProvider: .applePasswords, options: options, actions: &actions)
            } else {
                planOneWay(source: appleP, destination: oneP, key: key, sourceProvider: .applePasswords, destinationProvider: .onePassword, options: options, actions: &actions)
            }
        case (.none, .none):
            break
        }
    }

    private func resolveConflict(
        onePassword: CredentialRecord,
        apple: CredentialRecord,
        key _: CredentialKey,
        options: SyncOptions
    ) -> Provider? {
        if options.truthSource == .onePassword { return .onePassword }
        if options.truthSource == .applePasswords { return .applePasswords }

        switch options.conflictPolicy {
        case .interactive, .fail:
            return nil
        case .preferOnePassword:
            return .onePassword
        case .preferApple:
            return .applePasswords
        case .preferNewest:
            guard let oneDate = onePassword.modifiedAt, let appleDate = apple.modifiedAt else { return nil }
            return oneDate >= appleDate ? .onePassword : .applePasswords
        }
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

    private func unsupportedReason(
        source: CredentialRecord,
        destination: Provider,
        isUpdate: Bool,
        options: SyncOptions
    ) -> String? {
        if source.hasPasskey {
            return "Passkey migration is not available through the macOS Keychain password API or 1Password JSON item templates. Use a provider-supported Credential Exchange flow when available."
        }

        if destination == .applePasswords, source.totpURI != nil, !options.allowPasswordOnlyForUnsupportedSecurityMaterial {
            return "Apple Passwords verification-code writes are not exposed through the Keychain internet-password API. Refusing to drop the TOTP secret."
        }

        if destination == .onePassword, isUpdate {
            return nil
        }

        return nil
    }
}

