import Foundation
import PassSyncCore

enum SampleSimulationData {
    static let state = SimulationState(
        onePasswordRecords: [
            CredentialRecord(
                provider: .onePassword,
                sourceID: "onep-new-example",
                vaultID: "PassSync-Test",
                title: "New 1Password Example",
                username: "new@example.test",
                password: "onepassword-dummy-password",
                urls: ["https://new.example.test/login"],
                notes: "Synthetic 1Password record",
                hasPasskey: false,
                modifiedAt: iso8601("2026-06-13T12:00:00Z")
            ),
            CredentialRecord(
                provider: .onePassword,
                sourceID: "onep-conflict-example",
                vaultID: "PassSync-Test",
                title: "Conflict Example",
                username: "conflict@example.test",
                password: "onepassword-conflict-password",
                urls: ["https://conflict.example.test/login"],
                notes: "Synthetic conflict record",
                hasPasskey: false,
                modifiedAt: iso8601("2026-06-13T13:00:00Z")
            ),
            CredentialRecord(
                provider: .onePassword,
                sourceID: "onep-passkey-example",
                vaultID: "PassSync-Test",
                title: "Passkey Example",
                username: "passkey@example.test",
                password: "passkey-fallback-password",
                urls: ["https://passkey.example.test/login"],
                notes: "Synthetic passkey-bearing record; should be blocked",
                hasPasskey: true,
                modifiedAt: iso8601("2026-06-13T14:00:00Z")
            ),
            CredentialRecord(
                provider: .onePassword,
                sourceID: "onep-totp-example",
                vaultID: "PassSync-Test",
                title: "TOTP Example",
                username: "totp@example.test",
                password: "totp-dummy-password",
                urls: ["https://totp.example.test/login"],
                notes: "Synthetic TOTP record; blocked for Apple unless password-only mode is explicit",
                totpURI: "otpauth://totp/passsync:totp@example.test?secret=JBSWY3DPEHPK3PXP&issuer=PassSync",
                hasPasskey: false,
                modifiedAt: iso8601("2026-06-13T15:00:00Z")
            )
        ],
        appleRecords: [
            CredentialRecord(
                provider: .applePasswords,
                sourceID: "apple-existing-example",
                title: "Existing Apple Example",
                username: "conflict@example.test",
                password: "apple-dummy-password",
                urls: ["https://conflict.example.test/login"],
                notes: "Synthetic Apple Passwords record",
                hasPasskey: false,
                modifiedAt: iso8601("2026-06-12T12:00:00Z")
            )
        ]
    )

    private static func iso8601(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}
