import Foundation

public enum URLUtilities {
    public static func key(for record: CredentialRecord) -> CredentialKey? {
        guard let host = canonicalHost(from: record.urls.first) ?? canonicalHost(from: record.title) else {
            return nil
        }
        return CredentialKey(host: host, username: record.username)
    }

    public static func canonicalHost(from value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        if let url = URL(string: value), let host = url.host(percentEncoded: false), !host.isEmpty {
            return stripWWW(host)
        }

        if let url = URL(string: "https://\(value)"), let host = url.host(percentEncoded: false), !host.isEmpty {
            return stripWWW(host)
        }

        return nil
    }

    public static func primaryURL(for record: CredentialRecord) -> URL? {
        for candidate in record.urls {
            if let url = URL(string: candidate), url.host(percentEncoded: false) != nil {
                return url
            }
            if let url = URL(string: "https://\(candidate)"), url.host(percentEncoded: false) != nil {
                return url
            }
        }
        return nil
    }

    private static func stripWWW(_ host: String) -> String {
        let lower = host.lowercased()
        if lower.hasPrefix("www.") {
            return String(lower.dropFirst(4))
        }
        return lower
    }
}

