import Foundation

public enum SecretRedactor {
    private static let sensitiveKeys = [
        "password",
        "secret",
        "otp",
        "totp",
        "otpauth",
        "credential",
        "privatekey",
        "private_key"
    ]

    public static func redacted(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return value }
        return "<redacted:\(value.count)>"
    }

    public static func redactRecord(_ record: CredentialRecord) -> CredentialRecord {
        var copy = record
        copy.password = redacted(record.password) ?? ""
        copy.totpURI = redacted(record.totpURI)
        copy.rawFingerprint = nil
        return copy
    }

    public static func redactPlan(_ plan: SyncPlan) -> SyncPlan {
        var copy = plan
        copy.actions = plan.actions.map { action in
            var redactedAction = action
            if let source = action.sourceRecord {
                redactedAction.sourceRecord = redactRecord(source)
            }
            if let destination = action.destinationRecord {
                redactedAction.destinationRecord = redactRecord(destination)
            }
            return redactedAction
        }
        return copy
    }

    public static func redactJSONLikeString(_ text: String) -> String {
        var result = text
        for key in sensitiveKeys {
            let pattern = #"(?i)("\#(NSRegularExpression.escapedPattern(for: key))"\s*:\s*")[^"]*""#
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(result.startIndex..<result.endIndex, in: result)
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: range,
                    withTemplate: "$1<redacted>\""
                )
            }
        }
        result = result.replacingOccurrences(
            of: #"otpauth://[^\s"]+"#,
            with: "otpauth://<redacted>",
            options: .regularExpression
        )
        return result
    }
}

