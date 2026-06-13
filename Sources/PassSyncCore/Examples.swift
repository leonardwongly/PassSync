import Foundation

public struct SimulationExample: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var summary: String
    public var state: SimulationState

    public init(name: String, summary: String, state: SimulationState) {
        self.name = name
        self.summary = summary
        self.state = state
    }

    public var id: String { name }
}

public enum SimulationExamples {
    public static let all: [SimulationExample] = [
        minimal,
        conflict,
        totp,
        passkey,
        bidirectional
    ]

    public static func named(_ name: String) -> SimulationExample? {
        all.first { $0.name == name }
    }

    public static let minimal = SimulationExample(
        name: "minimal",
        summary: "One 1Password login that is missing from Apple Passwords.",
        state: SimulationState(
            onePasswordRecords: [
                CredentialRecord(
                    provider: .onePassword,
                    sourceID: "onep-minimal",
                    vaultID: "PassSync-Test",
                    title: "Minimal Example",
                    username: "alice@example.test",
                    password: "dummy-password",
                    urls: ["https://minimal.example.test/login"],
                    hasPasskey: false,
                    modifiedAt: exampleDate("2026-06-13T12:00:00Z")
                )
            ],
            appleRecords: []
        )
    )

    public static let conflict = SimulationExample(
        name: "conflict",
        summary: "Same account exists on both sides with different passwords.",
        state: SimulationState(
            onePasswordRecords: [
                CredentialRecord(
                    provider: .onePassword,
                    sourceID: "onep-conflict",
                    vaultID: "PassSync-Test",
                    title: "Conflict Example",
                    username: "conflict@example.test",
                    password: "onepassword-value",
                    urls: ["https://conflict.example.test/login"],
                    hasPasskey: false,
                    modifiedAt: exampleDate("2026-06-13T13:00:00Z")
                )
            ],
            appleRecords: [
                CredentialRecord(
                    provider: .applePasswords,
                    sourceID: "apple-conflict",
                    title: "Conflict Example",
                    username: "conflict@example.test",
                    password: "apple-value",
                    urls: ["https://conflict.example.test/login"],
                    hasPasskey: false,
                    modifiedAt: exampleDate("2026-06-12T13:00:00Z")
                )
            ]
        )
    )

    public static let totp = SimulationExample(
        name: "totp",
        summary: "1Password source record includes a TOTP seed that Apple Passwords cannot receive through Keychain APIs.",
        state: SimulationState(
            onePasswordRecords: [
                CredentialRecord(
                    provider: .onePassword,
                    sourceID: "onep-totp",
                    vaultID: "PassSync-Test",
                    title: "TOTP Example",
                    username: "totp@example.test",
                    password: "totp-dummy-password",
                    urls: ["https://totp.example.test/login"],
                    notes: "Synthetic TOTP record",
                    totpURI: "otpauth://totp/passsync:totp@example.test?secret=JBSWY3DPEHPK3PXP&issuer=PassSync",
                    hasPasskey: false,
                    modifiedAt: exampleDate("2026-06-13T15:00:00Z")
                )
            ],
            appleRecords: []
        )
    )

    public static let passkey = SimulationExample(
        name: "passkey",
        summary: "A passkey-bearing record that must remain blocked.",
        state: SimulationState(
            onePasswordRecords: [
                CredentialRecord(
                    provider: .onePassword,
                    sourceID: "onep-passkey",
                    vaultID: "PassSync-Test",
                    title: "Passkey Example",
                    username: "passkey@example.test",
                    password: "fallback-password",
                    urls: ["https://passkey.example.test/login"],
                    notes: "Synthetic passkey-bearing record",
                    hasPasskey: true,
                    modifiedAt: exampleDate("2026-06-13T14:00:00Z")
                )
            ],
            appleRecords: []
        )
    )

    public static let bidirectional = SimulationExample(
        name: "bidirectional",
        summary: "Mixed create, conflict, passkey-blocked, and TOTP-blocked cases.",
        state: SimulationState(
            onePasswordRecords: [
                minimal.state.onePasswordRecords[0],
                conflict.state.onePasswordRecords[0],
                passkey.state.onePasswordRecords[0],
                totp.state.onePasswordRecords[0]
            ],
            appleRecords: conflict.state.appleRecords
        )
    )

    private static func exampleDate(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}

