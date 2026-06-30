import Foundation

public enum PassSyncError: Error, CustomStringConvertible, Equatable {
    case invalidArguments(String)
    case unsupported(String)
    case commandFailed(command: String, status: Int32, stderr: String)
    case keychainError(operation: String, status: OSStatus)
    case backupRequired(String)
    case unsafeApply(String)
    case decodingFailed(String)

    public var description: String {
        switch self {
        case .invalidArguments(let message):
            return "invalid arguments: \(message)"
        case .unsupported(let message):
            return "unsupported: \(message)"
        case .commandFailed(let command, let status, let stderr):
            return "command failed (\(status)): \(command)\n\(stderr)"
        case .keychainError(let operation, let status):
            return "keychain \(operation) failed with OSStatus \(status)"
        case .backupRequired(let message):
            return "backup required: \(message)"
        case .unsafeApply(let message):
            return "unsafe apply refused: \(message)"
        case .decodingFailed(let message):
            return "decoding failed: \(message)"
        }
    }
}

public enum Provider: String, Codable, Sendable, CaseIterable {
    case onePassword = "1password"
    case applePasswords = "apple-passwords"
}

public enum SyncDirection: String, Codable, Sendable, CaseIterable {
    case onePasswordToApple = "1p-to-apple"
    case appleToOnePassword = "apple-to-1p"
    case bidirectional
}

public enum TruthSource: String, Codable, Sendable, CaseIterable {
    case none
    case onePassword = "1password"
    case applePasswords = "apple-passwords"
}

public enum ConflictPolicy: String, Codable, Sendable, CaseIterable {
    case interactive
    case fail
    case preferOnePassword = "prefer-1password"
    case preferApple = "prefer-apple"
    case preferNewest = "prefer-newest"
}

public enum RestoreTarget: String, Codable, Sendable, CaseIterable {
    case onePassword = "1password"
    case applePasswords = "apple-passwords"

    public var provider: Provider {
        switch self {
        case .onePassword:
            return .onePassword
        case .applePasswords:
            return .applePasswords
        }
    }
}

public struct CredentialRecord: Codable, Equatable, Sendable {
    public var provider: Provider
    public var sourceID: String?
    public var vaultID: String?
    public var title: String
    public var username: String
    public var password: String
    public var urls: [String]
    public var notes: String?
    public var totpURI: String?
    public var hasPasskey: Bool
    public var modifiedAt: Date?
    public var rawFingerprint: String?

    public init(
        provider: Provider,
        sourceID: String? = nil,
        vaultID: String? = nil,
        title: String,
        username: String,
        password: String,
        urls: [String],
        notes: String? = nil,
        totpURI: String? = nil,
        hasPasskey: Bool = false,
        modifiedAt: Date? = nil,
        rawFingerprint: String? = nil
    ) {
        self.provider = provider
        self.sourceID = sourceID
        self.vaultID = vaultID
        self.title = title
        self.username = username
        self.password = password
        self.urls = urls
        self.notes = notes
        self.totpURI = totpURI
        self.hasPasskey = hasPasskey
        self.modifiedAt = modifiedAt
        self.rawFingerprint = rawFingerprint
    }
}

public struct CredentialKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public var host: String
    public var username: String

    public init(host: String, username: String) {
        self.host = host.lowercased()
        self.username = username.lowercased()
    }

    public var description: String {
        "\(username)@\(host)"
    }
}

public enum SyncActionKind: String, Codable, Sendable {
    case createInOnePassword
    case createInApple
    case updateOnePassword
    case updateApple
    case skipIdentical
    case conflict
    case unsupported
}

public struct SyncAction: Codable, Equatable, Sendable {
    public var kind: SyncActionKind
    public var key: CredentialKey
    public var source: Provider?
    public var destination: Provider?
    public var reason: String
    public var sourceRecord: CredentialRecord?
    public var destinationRecord: CredentialRecord?

    public init(
        kind: SyncActionKind,
        key: CredentialKey,
        source: Provider?,
        destination: Provider?,
        reason: String,
        sourceRecord: CredentialRecord? = nil,
        destinationRecord: CredentialRecord? = nil
    ) {
        self.kind = kind
        self.key = key
        self.source = source
        self.destination = destination
        self.reason = reason
        self.sourceRecord = sourceRecord
        self.destinationRecord = destinationRecord
    }
}

public struct SyncPlan: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var direction: SyncDirection
    public var truthSource: TruthSource
    public var conflictPolicy: ConflictPolicy
    public var actions: [SyncAction]
    public var warnings: [String]

    public init(
        generatedAt: Date = Date(),
        direction: SyncDirection,
        truthSource: TruthSource,
        conflictPolicy: ConflictPolicy,
        actions: [SyncAction],
        warnings: [String]
    ) {
        self.generatedAt = generatedAt
        self.direction = direction
        self.truthSource = truthSource
        self.conflictPolicy = conflictPolicy
        self.actions = actions
        self.warnings = warnings
    }

    public var hasBlockingActions: Bool {
        actions.contains { $0.kind == .conflict || $0.kind == .unsupported }
    }

    public var mutatingActions: [SyncAction] {
        actions.filter {
            switch $0.kind {
            case .createInOnePassword, .createInApple, .updateOnePassword, .updateApple:
                return true
            case .skipIdentical, .conflict, .unsupported:
                return false
            }
        }
    }
}

public struct SyncOptions: Equatable, Sendable {
    public var direction: SyncDirection
    public var truthSource: TruthSource
    public var conflictPolicy: ConflictPolicy
    public var allowPasswordOnlyForUnsupportedSecurityMaterial: Bool

    public init(
        direction: SyncDirection,
        truthSource: TruthSource = .none,
        conflictPolicy: ConflictPolicy = .interactive,
        allowPasswordOnlyForUnsupportedSecurityMaterial: Bool = false
    ) {
        self.direction = direction
        self.truthSource = truthSource
        self.conflictPolicy = conflictPolicy
        self.allowPasswordOnlyForUnsupportedSecurityMaterial = allowPasswordOnlyForUnsupportedSecurityMaterial
    }
}

public enum CredentialField: String, Codable, Sendable, CaseIterable {
    case title
    case username
    case password
    case urls
    case notes
    case totpURI
    case hasPasskey
    case modifiedAt
}

public struct CredentialFieldDiff: Codable, Equatable, Sendable, Identifiable {
    public var field: CredentialField
    public var sourceValue: String
    public var destinationValue: String
    public var isSecret: Bool

    public init(field: CredentialField, sourceValue: String, destinationValue: String, isSecret: Bool = false) {
        self.field = field
        self.sourceValue = sourceValue
        self.destinationValue = destinationValue
        self.isSecret = isSecret
    }

    public var id: String { field.rawValue }
}
