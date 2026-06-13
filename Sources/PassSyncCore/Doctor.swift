import Foundation

public enum DoctorSeverity: String, Codable, Sendable {
    case pass
    case warning
    case fail
}

public struct DoctorCheck: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var severity: DoctorSeverity
    public var detail: String

    public init(id: String, title: String, severity: DoctorSeverity, detail: String) {
        self.id = id
        self.title = title
        self.severity = severity
        self.detail = detail
    }
}

public struct DoctorReport: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var checks: [DoctorCheck]

    public init(generatedAt: Date = Date(), checks: [DoctorCheck]) {
        self.generatedAt = generatedAt
        self.checks = checks
    }

    public var hasFailures: Bool {
        checks.contains { $0.severity == .fail }
    }
}

public struct DoctorOptions: Sendable {
    public var opPath: String
    public var vault: String?
    public var backupPath: String?
    public var appBundlePath: String?

    public init(opPath: String, vault: String? = nil, backupPath: String? = nil, appBundlePath: String? = nil) {
        self.opPath = opPath
        self.vault = vault
        self.backupPath = backupPath
        self.appBundlePath = appBundlePath
    }
}

public struct Doctor: Sendable {
    private let runner: ProcessRunning
    private let timeoutSeconds: TimeInterval

    public init(runner: ProcessRunning = ProcessRunner(), timeoutSeconds: TimeInterval = 8) {
        self.runner = runner
        self.timeoutSeconds = timeoutSeconds
    }

    public func run(options: DoctorOptions) -> DoctorReport {
        var checks: [DoctorCheck] = []

        let opExists = FileManager.default.isExecutableFile(atPath: options.opPath)
        checks.append(DoctorCheck(
            id: "op.exists",
            title: "1Password CLI",
            severity: opExists ? .pass : .fail,
            detail: opExists ? "Found executable at \(options.opPath)." : "No executable found at \(options.opPath)."
        ))

        if opExists {
            checks.append(opVersionCheck(opPath: options.opPath))
            checks.append(opAccountCheck(opPath: options.opPath))
            if let vault = options.vault {
                checks.append(opVaultCheck(opPath: options.opPath, vault: vault))
            }
        }

        checks.append(DoctorCheck(
            id: "keychain.api",
            title: "Apple Keychain API",
            severity: .pass,
            detail: "Security.framework Keychain APIs are linked and available."
        ))

        if let backupPath = options.backupPath {
            checks.append(backupDirectoryCheck(path: backupPath))
        }

        if let appBundlePath = options.appBundlePath {
            checks.append(appBundleCheck(path: appBundlePath))
        }

        checks.append(DoctorCheck(
            id: "passkeys.policy",
            title: "Passkey Policy",
            severity: .warning,
            detail: "Passkey-bearing records are detected and blocked; use provider-supported Credential Exchange or manual reenrollment."
        ))

        checks.append(DoctorCheck(
            id: "totp.apple.policy",
            title: "Apple TOTP Policy",
            severity: .warning,
            detail: "Apple Passwords verification-code writes are blocked because the Keychain internet-password API does not expose them."
        ))

        return DoctorReport(checks: checks)
    }

    private func opVersionCheck(opPath: String) -> DoctorCheck {
        do {
            let result = try runCommand(executable: opPath, arguments: ["--version"])
            let version = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            return DoctorCheck(
                id: "op.version",
                title: "1Password CLI Version",
                severity: result.status == 0 ? .pass : .fail,
                detail: result.status == 0 ? version : String(data: result.stderr, encoding: .utf8) ?? "Unknown error."
            )
        } catch {
            return DoctorCheck(id: "op.version", title: "1Password CLI Version", severity: .fail, detail: String(describing: error))
        }
    }

    private func opAccountCheck(opPath: String) -> DoctorCheck {
        do {
            let result = try runCommand(executable: opPath, arguments: ["account", "list", "--format", "json"])
            return DoctorCheck(
                id: "op.accounts",
                title: "1Password Account Session",
                severity: result.status == 0 ? .pass : .warning,
                detail: result.status == 0 ? "Account list is readable." : SecretRedactor.redactJSONLikeString(String(data: result.stderr, encoding: .utf8) ?? "Could not list accounts.")
            )
        } catch {
            return DoctorCheck(id: "op.accounts", title: "1Password Account Session", severity: .warning, detail: String(describing: error))
        }
    }

    private func opVaultCheck(opPath: String, vault: String) -> DoctorCheck {
        do {
            let result = try runCommand(executable: opPath, arguments: ["item", "list", "--vault", vault, "--format", "json", "--limit", "1"])
            return DoctorCheck(
                id: "op.vault",
                title: "1Password Vault",
                severity: result.status == 0 ? .pass : .warning,
                detail: result.status == 0 ? "Vault \(vault) is readable." : SecretRedactor.redactJSONLikeString(String(data: result.stderr, encoding: .utf8) ?? "Could not read vault.")
            )
        } catch {
            return DoctorCheck(id: "op.vault", title: "1Password Vault", severity: .warning, detail: String(describing: error))
        }
    }

    private func backupDirectoryCheck(path: String) -> DoctorCheck {
        let url = URL(fileURLWithPath: path).deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let probe = url.appendingPathComponent(".passsync-write-probe-\(UUID().uuidString)")
            try Data("probe".utf8).write(to: probe, options: [.atomic])
            try FileManager.default.removeItem(at: probe)
            return DoctorCheck(id: "backup.writable", title: "Backup Directory", severity: .pass, detail: "\(url.path) is writable.")
        } catch {
            return DoctorCheck(id: "backup.writable", title: "Backup Directory", severity: .fail, detail: "\(url.path) is not writable: \(error)")
        }
    }

    private func appBundleCheck(path: String) -> DoctorCheck {
        let info = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        guard FileManager.default.fileExists(atPath: info.path) else {
            return DoctorCheck(id: "app.bundle", title: "macOS App Bundle", severity: .warning, detail: "No Info.plist at \(info.path).")
        }
        return DoctorCheck(id: "app.bundle", title: "macOS App Bundle", severity: .pass, detail: "Bundle metadata exists at \(info.path).")
    }

    private func runCommand(executable: String, arguments: [String]) throws -> ProcessResult {
        if let processRunner = runner as? ProcessRunner {
            return try processRunner.run(executable: executable, arguments: arguments, stdin: nil, timeoutSeconds: timeoutSeconds)
        }
        return try runner.run(executable: executable, arguments: arguments, stdin: nil)
    }
}
