import CryptoKit
import Foundation
import CommonCrypto

public struct BackupPayload: Codable, Sendable {
    public var createdAt: Date
    public var formatVersion: Int
    public var onePasswordRecords: [CredentialRecord]
    public var appleRecords: [CredentialRecord]
    public var warnings: [String]

    public init(
        createdAt: Date = Date(),
        formatVersion: Int = 1,
        onePasswordRecords: [CredentialRecord],
        appleRecords: [CredentialRecord],
        warnings: [String]
    ) {
        self.createdAt = createdAt
        self.formatVersion = formatVersion
        self.onePasswordRecords = onePasswordRecords
        self.appleRecords = appleRecords
        self.warnings = warnings
    }
}

public struct EncryptedBackupEnvelope: Codable, Sendable {
    public var format: String
    public var kdf: String
    public var iterations: Int
    public var salt: Data
    public var nonce: Data
    public var ciphertext: Data
    public var tag: Data
}

public struct BackupManager: Sendable {
    public static let defaultIterations = 310_000

    public init() {}

    public func writeEncryptedBackup(payload: BackupPayload, passphrase: String, outputPath: String) throws {
        guard !passphrase.isEmpty else {
            throw PassSyncError.backupRequired("Backup passphrase cannot be empty.")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(payload)

        let salt = randomData(count: 32)
        let key = try deriveKey(kdf: "pbkdf2-hmac-sha256", passphrase: passphrase, salt: salt, iterations: Self.defaultIterations)
        let nonce = try AES.GCM.Nonce(data: randomData(count: 12))
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        guard let tag = sealed.tag.withUnsafeBytes({ Data($0) }) as Data?,
              let nonceData = sealed.nonce.withUnsafeBytes({ Data($0) }) as Data? else {
            throw PassSyncError.backupRequired("Could not construct encrypted backup envelope.")
        }

        let envelope = EncryptedBackupEnvelope(
            format: "passsync.encrypted-backup.v2",
            kdf: "pbkdf2-hmac-sha256",
            iterations: Self.defaultIterations,
            salt: salt,
            nonce: nonceData,
            ciphertext: sealed.ciphertext,
            tag: tag
        )

        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let envelopeData = try encoder.encode(envelope)
        guard FileManager.default.createFile(atPath: outputPath, contents: envelopeData, attributes: [.posixPermissions: 0o600]) else {
            throw PassSyncError.backupRequired("Could not create backup file at \(outputPath).")
        }
    }

    public func readEncryptedBackup(inputPath: String, passphrase: String) throws -> BackupPayload {
        let data = try Data(contentsOf: URL(fileURLWithPath: inputPath))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(EncryptedBackupEnvelope.self, from: data)
        let key = try deriveKey(kdf: envelope.kdf, passphrase: passphrase, salt: envelope.salt, iterations: envelope.iterations)
        let sealed = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: envelope.nonce),
            ciphertext: envelope.ciphertext,
            tag: envelope.tag
        )
        let plaintext = try AES.GCM.open(sealed, using: key)
        return try decoder.decode(BackupPayload.self, from: plaintext)
    }

    private func randomData(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes)
    }

    private func deriveKey(kdf: String, passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        switch kdf {
        case "pbkdf2-hmac-sha256":
            return try derivePBKDF2Key(passphrase: passphrase, salt: salt, iterations: iterations)
        case "sha256-iterated":
            return deriveLegacySHA256Key(passphrase: passphrase, salt: salt, iterations: iterations)
        default:
            throw PassSyncError.backupRequired("Unsupported backup KDF: \(kdf).")
        }
    }

    private func derivePBKDF2Key(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        let status = passphrase.withCString { passphraseBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passphraseBytes,
                    strlen(passphraseBytes),
                    saltBytes.bindMemory(to: UInt8.self).baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    &derived,
                    derived.count
                )
            }
        }
        guard status == kCCSuccess else {
            throw PassSyncError.backupRequired("PBKDF2 key derivation failed with status \(status).")
        }
        return SymmetricKey(data: Data(derived))
    }

    private func deriveLegacySHA256Key(passphrase: String, salt: Data, iterations: Int) -> SymmetricKey {
        var material = Data(passphrase.utf8) + salt
        for _ in 0..<iterations {
            material = Data(SHA256.hash(data: material + salt))
        }
        return SymmetricKey(data: material)
    }
}
