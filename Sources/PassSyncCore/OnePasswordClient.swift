import Foundation

public protocol OnePasswordManaging: Sendable {
    func fetchLogins(vault: String?) throws -> [CredentialRecord]
    func create(_ record: CredentialRecord, vault: String?) throws
    func update(_ record: CredentialRecord, existing: CredentialRecord, vault: String?) throws
}

public struct OnePasswordClient<Runner: ProcessRunning>: OnePasswordManaging {
    private let runner: Runner
    private let opPath: String
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(runner: Runner, opPath: String = "/opt/homebrew/bin/op") {
        self.runner = runner
        self.opPath = opPath
        decoder.dateDecodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
    }

    public func fetchLogins(vault: String?) throws -> [CredentialRecord] {
        var listArguments = ["item", "list", "--categories", "Login", "--format", "json"]
        if let vault {
            listArguments += ["--vault", vault]
        }

        let listResult = try checkedRun(listArguments)
        let summaries = try decoder.decode([OnePasswordItemListSummary].self, from: listResult.stdout)

        var records: [CredentialRecord] = []
        for summary in summaries {
            var getArguments = ["item", "get", summary.id, "--format", "json", "--reveal"]
            if let vault {
                getArguments += ["--vault", vault]
            }
            let detailResult = try checkedRun(getArguments)
            let detail = try decoder.decode(OnePasswordItemDetail.self, from: detailResult.stdout)
            if let record = try mapDetail(detail, raw: detailResult.stdout) {
                records.append(record)
            }
        }
        return records
    }

    public func auditItemCategories(vault: String?) throws -> ItemCategoryAuditReport {
        var listArguments = ["item", "list", "--format", "json"]
        if let vault {
            listArguments += ["--vault", vault]
        }
        let listResult = try checkedRun(listArguments)
        let summaries = try decoder.decode([OnePasswordItemListSummary].self, from: listResult.stdout)
        return ItemCategoryAuditor().auditOnePasswordSummaries(summaries)
    }

    public func create(_ record: CredentialRecord, vault: String?) throws {
        let payload = try makeTemplate(record: record, existingID: nil)
        var arguments = ["item", "create", "-"]
        if let vault {
            arguments += ["--vault", vault]
        }
        _ = try checkedRun(arguments, stdin: payload)
    }

    public func update(_ record: CredentialRecord, existing: CredentialRecord, vault: String?) throws {
        guard let id = existing.sourceID else {
            throw PassSyncError.invalidArguments("Cannot update a 1Password item without sourceID.")
        }
        if existing.hasPasskey {
            throw PassSyncError.unsafeApply("Refusing to edit 1Password item \(id) because it appears to contain passkey data.")
        }
        let payload = try makeTemplate(record: record, existingID: id)
        var arguments = ["item", "edit", id]
        if let vault {
            arguments += ["--vault", vault]
        }
        _ = try checkedRun(arguments, stdin: payload)
    }

    private func checkedRun(_ arguments: [String], stdin: Data? = nil) throws -> ProcessResult {
        let result = try runner.run(executable: opPath, arguments: arguments, stdin: stdin)
        if result.status != 0 {
            let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
            throw PassSyncError.commandFailed(
                command: "op \(arguments.joined(separator: " "))",
                status: result.status,
                stderr: SecretRedactor.redactJSONLikeString(stderr)
            )
        }
        return result
    }

    private func mapDetail(_ detail: OnePasswordItemDetail, raw: Data) throws -> CredentialRecord? {
        guard detail.category.uppercased() == "LOGIN" else { return nil }
        let username = detail.firstField(purpose: "USERNAME", id: "username") ?? ""
        let password = detail.firstField(purpose: "PASSWORD", id: "password") ?? ""
        guard !password.isEmpty else { return nil }
        let notes = detail.firstField(purpose: "NOTES", id: "notesPlain")
        let totp = detail.fields.first { $0.type.uppercased() == "OTP" || ($0.value?.hasPrefix("otpauth://") ?? false) }?.value
        let urls = detail.urls?.compactMap(\.href) ?? []
        let rawJSON = try JSONSerialization.jsonObject(with: raw)
        let hasPasskey = JSONEvidenceScanner.containsPasskeyEvidence(rawJSON)
        return CredentialRecord(
            provider: .onePassword,
            sourceID: detail.id,
            vaultID: detail.vault?.id,
            title: detail.title,
            username: username,
            password: password,
            urls: urls,
            notes: notes,
            totpURI: totp,
            hasPasskey: hasPasskey,
            modifiedAt: detail.updatedAt,
            rawFingerprint: SHA256Fingerprint.hex(raw)
        )
    }

    private func makeTemplate(record: CredentialRecord, existingID: String?) throws -> Data {
        var fields: [[String: Any]] = [
            [
                "id": "username",
                "type": "STRING",
                "purpose": "USERNAME",
                "label": "username",
                "value": record.username
            ],
            [
                "id": "password",
                "type": "CONCEALED",
                "purpose": "PASSWORD",
                "label": "password",
                "value": record.password
            ],
            [
                "id": "notesPlain",
                "type": "STRING",
                "purpose": "NOTES",
                "label": "notesPlain",
                "value": record.notes ?? ""
            ]
        ]

        if let totpURI = record.totpURI, !totpURI.isEmpty {
            fields.append([
                "id": "passsync_totp",
                "type": "OTP",
                "label": "PassSync TOTP",
                "value": totpURI
            ])
        }

        var payload: [String: Any] = [
            "title": record.title,
            "category": "LOGIN",
            "fields": fields,
            "urls": record.urls.map { ["href": $0] }
        ]
        if let existingID {
            payload["id"] = existingID
        }
        if let vaultID = record.vaultID {
            payload["vault"] = ["id": vaultID]
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }
}

private struct OnePasswordItemDetail: Decodable {
    var id: String
    var title: String
    var category: String
    var vault: OnePasswordVault?
    var urls: [OnePasswordURL]?
    var fields: [OnePasswordField]
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case category
        case vault
        case urls
        case fields
        case updatedAt = "updated_at"
    }

    func firstField(purpose: String, id: String) -> String? {
        fields.first { $0.purpose?.uppercased() == purpose }?.value ??
            fields.first { $0.id == id || $0.label == id }?.value
    }
}

private struct OnePasswordVault: Decodable {
    var id: String
}

private struct OnePasswordURL: Decodable {
    var href: String?
}

private struct OnePasswordField: Decodable {
    var id: String?
    var type: String
    var purpose: String?
    var label: String?
    var value: String?
}

private enum JSONEvidenceScanner {
    static func containsPasskeyEvidence(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            for (key, nested) in dictionary {
                let lower = key.lowercased()
                if lower.contains("passkey") || lower.contains("webauthn") || lower.contains("credentialid") {
                    return true
                }
                if containsPasskeyEvidence(nested) {
                    return true
                }
            }
        } else if let array = value as? [Any] {
            return array.contains { containsPasskeyEvidence($0) }
        } else if let string = value as? String {
            let lower = string.lowercased()
            return lower.contains("passkey") || lower.contains("webauthn")
        }
        return false
    }
}
