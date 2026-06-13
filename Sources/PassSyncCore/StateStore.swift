import Foundation
import SQLite3

public struct StateCredentialSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var provider: Provider
    public var key: CredentialKey
    public var sourceID: String?
    public var vaultID: String?
    public var title: String
    public var urlCount: Int
    public var hasTOTP: Bool
    public var hasPasskey: Bool
    public var modifiedAt: Date?
    public var rawFingerprint: String?
    public var observedAt: Date

    public init(
        provider: Provider,
        key: CredentialKey,
        sourceID: String?,
        vaultID: String?,
        title: String,
        urlCount: Int,
        hasTOTP: Bool,
        hasPasskey: Bool,
        modifiedAt: Date?,
        rawFingerprint: String?,
        observedAt: Date
    ) {
        self.provider = provider
        self.key = key
        self.sourceID = sourceID
        self.vaultID = vaultID
        self.title = title
        self.urlCount = urlCount
        self.hasTOTP = hasTOTP
        self.hasPasskey = hasPasskey
        self.modifiedAt = modifiedAt
        self.rawFingerprint = rawFingerprint
        self.observedAt = observedAt
    }

    public init(record: CredentialRecord, key: CredentialKey, observedAt: Date = Date()) {
        self.provider = record.provider
        self.key = key
        self.sourceID = record.sourceID
        self.vaultID = record.vaultID
        self.title = record.title
        self.urlCount = record.urls.count
        self.hasTOTP = record.totpURI != nil
        self.hasPasskey = record.hasPasskey
        self.modifiedAt = record.modifiedAt
        self.rawFingerprint = record.rawFingerprint
        self.observedAt = observedAt
    }

    public var id: String { "\(provider.rawValue)-\(key.description)" }
}

public struct StateStoreSummary: Codable, Equatable, Sendable {
    public var path: String
    public var schemaVersion: Int
    public var credentialCount: Int
    public var decisionFileCount: Int
    public var receiptCount: Int
    public var latestObservationAt: Date?
}

public struct StateStore: Sendable {
    public static let currentSchemaVersion = 1

    public var path: String

    public init(path: String) {
        self.path = path
    }

    public func initialize() throws {
        try withDatabase { db in
            let version = try schemaVersion(db)
            guard version <= Self.currentSchemaVersion else {
                throw PassSyncError.unsupported("State store schema version \(version) is newer than this PassSync build supports.")
            }
            try createV1Schema(db)
            if version < Self.currentSchemaVersion {
                try setSchemaVersion(Self.currentSchemaVersion, db: db)
            }
        }
    }

    public func schemaVersion() throws -> Int {
        try initialize()
        return try withDatabase { db in
            try schemaVersion(db)
        }
    }

    public func recordCredentials(_ records: [CredentialRecord], observedAt: Date = Date()) throws -> Int {
        try initialize()
        return try withDatabase { db in
            var count = 0
            for record in records {
                guard let key = URLUtilities.key(for: record) else { continue }
                let snapshot = StateCredentialSnapshot(record: record, key: key, observedAt: observedAt)
                try upsert(snapshot, db: db)
                count += 1
            }
            return count
        }
    }

    public func recordDecisionFile(path: String) throws {
        try initialize()
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decisionFile = try decoder.decode(PlanDecisionFile.self, from: data)
        try withDatabase { db in
            try upsertDecisionFile(path: path, sha256: SHA256Fingerprint.hex(data), decisionFile: decisionFile, db: db)
        }
    }

    public func recordReceipt(path: String) throws {
        try initialize()
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let receipt = try decoder.decode(ApplyReceipt.self, from: data)
        try withDatabase { db in
            try upsertReceipt(path: path, sha256: SHA256Fingerprint.hex(data), receipt: receipt, db: db)
        }
    }

    public func summary() throws -> StateStoreSummary {
        try initialize()
        return try withDatabase { db in
            StateStoreSummary(
                path: path,
                schemaVersion: try schemaVersion(db),
                credentialCount: try scalarInt(db, "SELECT COUNT(*) FROM credential_snapshots;"),
                decisionFileCount: try scalarInt(db, "SELECT COUNT(*) FROM decision_files;"),
                receiptCount: try scalarInt(db, "SELECT COUNT(*) FROM apply_receipts;"),
                latestObservationAt: try scalarDate(db, "SELECT MAX(observed_at) FROM credential_snapshots;")
            )
        }
    }

    public func credentialSnapshots(limit: Int = 100) throws -> [StateCredentialSnapshot] {
        try initialize()
        return try withDatabase { db in
            let sql = """
            SELECT provider, host, username, source_id, vault_id, title, url_count, has_totp, has_passkey, modified_at, raw_fingerprint, observed_at
            FROM credential_snapshots
            ORDER BY observed_at DESC, provider, host, username
            LIMIT ?;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw sqliteError(db, context: "prepare credential snapshot list")
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(limit))
            var snapshots: [StateCredentialSnapshot] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let provider = Provider(rawValue: stringColumn(statement, 0)) ?? .onePassword
                let key = CredentialKey(host: stringColumn(statement, 1), username: stringColumn(statement, 2))
                snapshots.append(StateCredentialSnapshot(
                    provider: provider,
                    key: key,
                    sourceID: optionalStringColumn(statement, 3),
                    vaultID: optionalStringColumn(statement, 4),
                    title: stringColumn(statement, 5),
                    urlCount: Int(sqlite3_column_int(statement, 6)),
                    hasTOTP: sqlite3_column_int(statement, 7) == 1,
                    hasPasskey: sqlite3_column_int(statement, 8) == 1,
                    modifiedAt: parseDate(optionalStringColumn(statement, 9)),
                    rawFingerprint: optionalStringColumn(statement, 10),
                    observedAt: parseDate(optionalStringColumn(statement, 11)) ?? .distantPast
                ))
            }
            return snapshots
        }
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw PassSyncError.decodingFailed("Could not open state store at \(path).")
        }
        defer { sqlite3_close(db) }
        return try body(db)
    }

    private func upsert(_ snapshot: StateCredentialSnapshot, db: OpaquePointer) throws {
        let sql = """
        INSERT INTO credential_snapshots (
          provider, host, username, source_id, vault_id, title, url_count, has_totp, has_passkey, modified_at, raw_fingerprint, observed_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(provider, host, username) DO UPDATE SET
          source_id=excluded.source_id,
          vault_id=excluded.vault_id,
          title=excluded.title,
          url_count=excluded.url_count,
          has_totp=excluded.has_totp,
          has_passkey=excluded.has_passkey,
          modified_at=excluded.modified_at,
          raw_fingerprint=excluded.raw_fingerprint,
          observed_at=excluded.observed_at;
        """
        try withStatement(db, sql) { statement in
            bind(statement, 1, snapshot.provider.rawValue)
            bind(statement, 2, snapshot.key.host)
            bind(statement, 3, snapshot.key.username)
            bind(statement, 4, snapshot.sourceID)
            bind(statement, 5, snapshot.vaultID)
            bind(statement, 6, snapshot.title)
            sqlite3_bind_int(statement, 7, Int32(snapshot.urlCount))
            sqlite3_bind_int(statement, 8, snapshot.hasTOTP ? 1 : 0)
            sqlite3_bind_int(statement, 9, snapshot.hasPasskey ? 1 : 0)
            bind(statement, 10, formatDate(snapshot.modifiedAt))
            bind(statement, 11, snapshot.rawFingerprint)
            bind(statement, 12, formatDate(snapshot.observedAt))
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw sqliteError(db, context: "upsert credential snapshot")
            }
        }
    }

    private func upsertDecisionFile(path: String, sha256: String, decisionFile: PlanDecisionFile, db: OpaquePointer) throws {
        let sql = """
        INSERT OR REPLACE INTO decision_files (id, path, sha256, generated_at, plan_generated_at, direction, decision_count)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        try withStatement(db, sql) { statement in
            bind(statement, 1, sha256)
            bind(statement, 2, path)
            bind(statement, 3, sha256)
            bind(statement, 4, formatDate(decisionFile.generatedAt))
            bind(statement, 5, formatDate(decisionFile.planGeneratedAt))
            bind(statement, 6, decisionFile.direction.rawValue)
            sqlite3_bind_int(statement, 7, Int32(decisionFile.decisions.count))
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw sqliteError(db, context: "upsert decision file")
            }
        }
    }

    private func upsertReceipt(path: String, sha256: String, receipt: ApplyReceipt, db: OpaquePointer) throws {
        let sql = """
        INSERT OR REPLACE INTO apply_receipts (id, path, sha256, created_at, operation, backup_path, action_count, mutating_action_count)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
        try withStatement(db, sql) { statement in
            bind(statement, 1, receipt.id.uuidString)
            bind(statement, 2, path)
            bind(statement, 3, sha256)
            bind(statement, 4, formatDate(receipt.createdAt))
            bind(statement, 5, receipt.operation.rawValue)
            bind(statement, 6, receipt.backupPath)
            sqlite3_bind_int(statement, 7, Int32(receipt.actionCount))
            sqlite3_bind_int(statement, 8, Int32(receipt.mutatingActionCount))
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw sqliteError(db, context: "upsert receipt")
            }
        }
    }

    private func createV1Schema(_ db: OpaquePointer) throws {
        try execute(db, """
        CREATE TABLE IF NOT EXISTS credential_snapshots (
          provider TEXT NOT NULL,
          host TEXT NOT NULL,
          username TEXT NOT NULL,
          source_id TEXT,
          vault_id TEXT,
          title TEXT NOT NULL,
          url_count INTEGER NOT NULL,
          has_totp INTEGER NOT NULL,
          has_passkey INTEGER NOT NULL,
          modified_at TEXT,
          raw_fingerprint TEXT,
          observed_at TEXT NOT NULL,
          PRIMARY KEY(provider, host, username)
        );
        """)
        try execute(db, """
        CREATE TABLE IF NOT EXISTS decision_files (
          id TEXT PRIMARY KEY,
          path TEXT NOT NULL,
          sha256 TEXT NOT NULL,
          generated_at TEXT NOT NULL,
          plan_generated_at TEXT NOT NULL,
          direction TEXT NOT NULL,
          decision_count INTEGER NOT NULL
        );
        """)
        try execute(db, """
        CREATE TABLE IF NOT EXISTS apply_receipts (
          id TEXT PRIMARY KEY,
          path TEXT NOT NULL,
          sha256 TEXT NOT NULL,
          created_at TEXT NOT NULL,
          operation TEXT NOT NULL,
          backup_path TEXT NOT NULL,
          action_count INTEGER NOT NULL,
          mutating_action_count INTEGER NOT NULL
        );
        """)
    }

    private func schemaVersion(_ db: OpaquePointer) throws -> Int {
        try scalarInt(db, "PRAGMA user_version;")
    }

    private func setSchemaVersion(_ version: Int, db: OpaquePointer) throws {
        try execute(db, "PRAGMA user_version = \(version);")
    }

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw sqliteError(db, context: "execute SQL")
        }
    }

    private func withStatement(_ db: OpaquePointer, _ sql: String, body: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw sqliteError(db, context: "prepare SQL")
        }
        defer { sqlite3_finalize(statement) }
        try body(statement)
    }

    private func scalarInt(_ db: OpaquePointer, _ sql: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw sqliteError(db, context: "prepare scalar int")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func scalarDate(_ db: OpaquePointer, _ sql: String) throws -> Date? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw sqliteError(db, context: "prepare scalar date")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return parseDate(optionalStringColumn(statement, 0))
    }

    private func sqliteError(_ db: OpaquePointer, context: String) -> PassSyncError {
        PassSyncError.decodingFailed("\(context): \(String(cString: sqlite3_errmsg(db)))")
    }
}

private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
    guard let value else {
        sqlite3_bind_null(statement, index)
        return
    }
    sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
}

private func stringColumn(_ statement: OpaquePointer?, _ index: Int32) -> String {
    optionalStringColumn(statement, index) ?? ""
}

private func optionalStringColumn(_ statement: OpaquePointer?, _ index: Int32) -> String? {
    guard let text = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: text)
}

private func formatDate(_ date: Date?) -> String? {
    guard let date else { return nil }
    return ISO8601DateFormatter().string(from: date)
}

private func parseDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    return ISO8601DateFormatter().date(from: value)
}
