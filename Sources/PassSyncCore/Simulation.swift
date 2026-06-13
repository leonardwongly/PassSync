import Foundation

public struct SimulationState: Codable, Equatable, Sendable {
    public var onePasswordRecords: [CredentialRecord]
    public var appleRecords: [CredentialRecord]

    public init(onePasswordRecords: [CredentialRecord], appleRecords: [CredentialRecord]) {
        self.onePasswordRecords = onePasswordRecords.map { $0.withProvider(.onePassword) }
        self.appleRecords = appleRecords.map { $0.withProvider(.applePasswords) }
    }
}

public final class SimulationStore: OnePasswordManaging, ApplePasswordsManaging, @unchecked Sendable {
    public private(set) var state: SimulationState

    public init(state: SimulationState) {
        self.state = state
    }

    public func fetchLogins(vault: String?) throws -> [CredentialRecord] {
        if let vault {
            return state.onePasswordRecords.filter { $0.vaultID == vault }
        }
        return state.onePasswordRecords
    }

    public func fetchLogins() throws -> [CredentialRecord] {
        state.appleRecords
    }

    public func create(_ record: CredentialRecord, vault: String?) throws {
        var copy = record.withProvider(.onePassword)
        if let vault {
            copy.vaultID = vault
        }
        if copy.sourceID == nil {
            copy.sourceID = "sim-1p-\(UUID().uuidString)"
        }
        state.onePasswordRecords.append(copy)
    }

    public func update(_ record: CredentialRecord, existing: CredentialRecord, vault: String?) throws {
        var copy = record.withProvider(.onePassword)
        copy.sourceID = existing.sourceID ?? copy.sourceID
        copy.vaultID = vault ?? existing.vaultID ?? copy.vaultID
        try replace(record: copy, existing: existing, in: &state.onePasswordRecords, provider: .onePassword)
    }

    public func create(_ record: CredentialRecord) throws {
        var copy = appleCompatible(record)
        if copy.sourceID == nil {
            copy.sourceID = "sim-apple-\(UUID().uuidString)"
        }
        state.appleRecords.append(copy)
    }

    public func update(_ record: CredentialRecord, existing: CredentialRecord) throws {
        var copy = appleCompatible(record)
        copy.sourceID = existing.sourceID ?? copy.sourceID
        try replace(record: copy, existing: existing, in: &state.appleRecords, provider: .applePasswords)
    }

    private func replace(
        record: CredentialRecord,
        existing: CredentialRecord,
        in records: inout [CredentialRecord],
        provider: Provider
    ) throws {
        if let sourceID = existing.sourceID,
           let index = records.firstIndex(where: { $0.sourceID == sourceID }) {
            records[index] = record.withProvider(provider)
            return
        }

        if let existingKey = URLUtilities.key(for: existing),
           let index = records.firstIndex(where: { URLUtilities.key(for: $0) == existingKey }) {
            records[index] = record.withProvider(provider)
            return
        }

        throw PassSyncError.invalidArguments("Simulation could not find existing \(provider.rawValue) record to update.")
    }

    private func appleCompatible(_ record: CredentialRecord) -> CredentialRecord {
        var copy = record.withProvider(.applePasswords)
        copy.totpURI = nil
        copy.hasPasskey = false
        return copy
    }
}

public extension CredentialRecord {
    func withProvider(_ provider: Provider) -> CredentialRecord {
        var copy = self
        copy.provider = provider
        return copy
    }
}
