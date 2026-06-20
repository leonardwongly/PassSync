import Foundation

public enum CredentialDiff {
    public static func fieldDiffs(source: CredentialRecord, destination: CredentialRecord, redacted: Bool = true) -> [CredentialFieldDiff] {
        var diffs: [CredentialFieldDiff] = []
        append(&diffs, field: .title, source: source.title, destination: destination.title)
        append(&diffs, field: .username, source: source.username, destination: destination.username)
        append(&diffs, field: .password, source: source.password, destination: destination.password, isSecret: true, redacted: redacted)
        append(&diffs, field: .urls, source: normalizedURLs(source.urls), destination: normalizedURLs(destination.urls))
        append(&diffs, field: .notes, source: source.notes ?? "", destination: destination.notes ?? "", isSecret: true, redacted: redacted)
        append(&diffs, field: .totpURI, source: source.totpURI ?? "", destination: destination.totpURI ?? "", isSecret: true, redacted: redacted)
        append(&diffs, field: .hasPasskey, source: String(source.hasPasskey), destination: String(destination.hasPasskey))
        append(&diffs, field: .modifiedAt, source: format(source.modifiedAt), destination: format(destination.modifiedAt))
        return diffs
    }

    private static func append(
        _ diffs: inout [CredentialFieldDiff],
        field: CredentialField,
        source: String,
        destination: String,
        isSecret: Bool = false,
        redacted: Bool = true
    ) {
        guard source != destination else { return }
        diffs.append(CredentialFieldDiff(
            field: field,
            sourceValue: isSecret && redacted ? (SecretRedactor.redacted(source) ?? "") : source,
            destinationValue: isSecret && redacted ? (SecretRedactor.redacted(destination) ?? "") : destination,
            isSecret: isSecret
        ))
    }

    private static func normalizedURLs(_ urls: [String]) -> String {
        urls.map { URLUtilities.canonicalHost(from: $0) ?? $0.lowercased() }
            .sorted()
            .joined(separator: ", ")
    }

    private static func format(_ date: Date?) -> String {
        guard let date else { return "" }
        return ISO8601DateFormatter().string(from: date)
    }
}
