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
    public var auditPath: String?
    public var appBundlePath: String?
    public var releaseScriptPath: String?

    public init(
        opPath: String,
        vault: String? = nil,
        backupPath: String? = nil,
        auditPath: String? = nil,
        appBundlePath: String? = nil,
        releaseScriptPath: String? = nil
    ) {
        self.opPath = opPath
        self.vault = vault
        self.backupPath = backupPath
        self.auditPath = auditPath
        self.appBundlePath = appBundlePath
        self.releaseScriptPath = releaseScriptPath
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

        if let auditPath = options.auditPath {
            checks.append(writableDirectoryCheck(
                id: "audit.writable",
                title: "Audit Directory",
                path: auditPath,
                treatsPathAsFile: false
            ))
        }

        if let appBundlePath = options.appBundlePath {
            checks.append(contentsOf: appBundleChecks(path: appBundlePath))
        }

        if let releaseScriptPath = options.releaseScriptPath {
            checks.append(releaseScriptCheck(path: releaseScriptPath))
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
        writableDirectoryCheck(
            id: "backup.writable",
            title: "Backup Directory",
            path: path,
            treatsPathAsFile: true
        )
    }

    private func writableDirectoryCheck(id: String, title: String, path: String, treatsPathAsFile: Bool) -> DoctorCheck {
        let url = treatsPathAsFile ? URL(fileURLWithPath: path).deletingLastPathComponent() : URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let probe = url.appendingPathComponent(".passsync-write-probe-\(UUID().uuidString)")
            try Data("probe".utf8).write(to: probe, options: [.atomic])
            try FileManager.default.removeItem(at: probe)
            return DoctorCheck(id: id, title: title, severity: .pass, detail: "\(url.path) is writable.")
        } catch {
            return DoctorCheck(id: id, title: title, severity: .fail, detail: "\(url.path) is not writable: \(error)")
        }
    }

    private func appBundleChecks(path: String) -> [DoctorCheck] {
        let info = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        guard FileManager.default.fileExists(atPath: info.path) else {
            return [
                DoctorCheck(id: "app.bundle", title: "macOS App Bundle", severity: .warning, detail: "No Info.plist at \(info.path).")
            ]
        }
        var checks = [
            DoctorCheck(id: "app.bundle", title: "macOS App Bundle", severity: .pass, detail: "Bundle metadata exists at \(info.path).")
        ]
        if let infoDictionary = NSDictionary(contentsOf: info),
           let version = infoDictionary["CFBundleShortVersionString"] as? String,
           let identifier = infoDictionary["CFBundleIdentifier"] as? String {
            checks.append(DoctorCheck(
                id: "app.bundle.version",
                title: "macOS App Version",
                severity: .pass,
                detail: "\(identifier) \(version)"
            ))
        } else {
            checks.append(DoctorCheck(
                id: "app.bundle.version",
                title: "macOS App Version",
                severity: .warning,
                detail: "Could not read bundle identifier and short version from Info.plist."
            ))
        }
        checks.append(appSigningCheck(path: path))
        return checks
    }

    private func appSigningCheck(path: String) -> DoctorCheck {
        do {
            let result = try runCommand(executable: "/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", path])
            return DoctorCheck(
                id: "app.signing",
                title: "macOS App Signing",
                severity: result.status == 0 ? .pass : .warning,
                detail: result.status == 0 ? "App bundle signature verifies." : SecretRedactor.redactJSONLikeString(String(data: result.stderr, encoding: .utf8) ?? "App bundle is unsigned or signature verification failed.")
            )
        } catch {
            return DoctorCheck(id: "app.signing", title: "macOS App Signing", severity: .warning, detail: String(describing: error))
        }
    }

    private func releaseScriptCheck(path: String) -> DoctorCheck {
        let executable = FileManager.default.isExecutableFile(atPath: path)
        return DoctorCheck(
            id: "release.script",
            title: "Release Packaging Script",
            severity: executable ? .pass : .warning,
            detail: executable ? "\(path) is executable." : "\(path) is not executable or does not exist."
        )
    }

    private func runCommand(executable: String, arguments: [String]) throws -> ProcessResult {
        if let processRunner = runner as? ProcessRunner {
            return try processRunner.run(executable: executable, arguments: arguments, stdin: nil, timeoutSeconds: timeoutSeconds)
        }
        return try runner.run(executable: executable, arguments: arguments, stdin: nil)
    }
}
