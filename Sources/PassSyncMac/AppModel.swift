import Foundation
import PassSyncCore

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedSection: AppSection = .dashboard
    @Published var preflight: Loadable<PreflightReport> = .idle
    @Published var simulationPlan: SyncPlan?
    @Published var livePlan: SyncPlan?
    @Published var restorePlan: SyncPlan?
    @Published var simulationMessage: String?
    @Published var liveMessage: String?
    @Published var liveError: String?
    @Published var restoreMessage: String?
    @Published var restoreError: String?
    @Published var isRunningSimulation = false
    @Published var isRunningLivePlan = false
    @Published var isApplyingLivePlan = false
    @Published var isRunningRestorePlan = false
    @Published var isApplyingRestorePlan = false

    @Published var simulationDirection: SyncDirection = .bidirectional
    @Published var simulationTruthSource: TruthSource = .none
    @Published var simulationConflictPolicy: ConflictPolicy = .interactive
    @Published var simulationVault = "PassSync-Test"
    @Published var simulationAllowPasswordOnly = false
    @Published var simulationOutputPath = "/tmp/passsync-sim-output.json"

    @Published var liveDirection: SyncDirection = .bidirectional
    @Published var liveTruthSource: TruthSource = .none
    @Published var liveConflictPolicy: ConflictPolicy = .interactive
    @Published var liveVault = ""
    @Published var liveAllowPasswordOnly = false
    @Published var opPath = "/opt/homebrew/bin/op"
    @Published var backupPath = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.passsync/backups/passsync-app.psbackup"
    @Published var backupPassphrase = ""

    @Published var restoreBackupPath = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.passsync/backups/passsync-app.psbackup"
    @Published var restoreTarget: RestoreTarget = .onePassword
    @Published var restoreVault = ""
    @Published var restorePassphrase = ""
    @Published var restoreAllowPasswordOnly = false

    private var liveSnapshot: (onePassword: [CredentialRecord], apple: [CredentialRecord])?
    private var restoreSnapshot: [CredentialRecord]?

    func runPreflight() async {
        preflight = .loading
        do {
            let report = try await Task.detached { () throws -> PreflightReport in
                let runner = ProcessRunner()
                let opPath = "/opt/homebrew/bin/op"
                let opExists = FileManager.default.isExecutableFile(atPath: opPath)
                var opVersion: String?
                if opExists {
                    let result = try runner.run(executable: opPath, arguments: ["--version"], stdin: nil)
                    if result.status == 0 {
                        opVersion = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                return PreflightReport(
                    opPath: opPath,
                    opFound: opExists,
                    opVersion: opVersion,
                    keychainAvailable: true,
                    notes: [
                        "Passkeys require provider-supported Credential Exchange or manual reenrollment.",
                        "Apple Passwords verification-code writes are not available through the Keychain internet-password API."
                    ]
                )
            }.value
            preflight = .loaded(report)
        } catch {
            preflight = .failed(error.localizedDescription)
        }
    }

    func runSimulationPlan() async {
        isRunningSimulation = true
        simulationMessage = nil
        defer { isRunningSimulation = false }

        let options = SyncOptions(
            direction: simulationDirection,
            truthSource: simulationTruthSource,
            conflictPolicy: simulationConflictPolicy,
            allowPasswordOnlyForUnsupportedSecurityMaterial: simulationAllowPasswordOnly
        )
        let state = SampleSimulationData.state
        let store = SimulationStore(state: state)
        do {
            let plan = SyncPlanner().buildPlan(
                onePasswordRecords: try store.fetchLogins(vault: normalizedVault(simulationVault)),
                appleRecords: try store.fetchLogins(),
                options: options
            )
            simulationPlan = plan
            simulationMessage = "Simulation plan generated with \(plan.actions.count) actions."
        } catch {
            simulationMessage = "Simulation failed: \(error)"
        }
    }

    func writeSimulationOutput() async {
        guard let plan = simulationPlan else {
            simulationMessage = "Run a simulation plan first."
            return
        }

        do {
            let store = SimulationStore(state: SampleSimulationData.state)
            try SyncExecutor(onePassword: store, applePasswords: store).apply(
                plan: plan,
                onePasswordVault: normalizedVault(simulationVault)
            )
            try writeSimulationState(store.state, path: simulationOutputPath)
            simulationMessage = "Wrote simulated output to \(simulationOutputPath)."
        } catch {
            simulationMessage = "Could not write simulated output: \(error)"
        }
    }

    func runLivePlan() async {
        isRunningLivePlan = true
        liveMessage = nil
        liveError = nil
        livePlan = nil
        defer { isRunningLivePlan = false }

        let direction = liveDirection
        let truthSource = liveTruthSource
        let conflictPolicy = liveConflictPolicy
        let allowPasswordOnly = liveAllowPasswordOnly
        let opPath = opPath
        let vault = normalizedVault(liveVault)

        do {
            let result = try await Task.detached { () throws -> (SyncPlan, [CredentialRecord], [CredentialRecord]) in
                let onePassword = OnePasswordClient(runner: ProcessRunner(), opPath: opPath)
                let apple = AppleKeychainClient()
                let onePasswordRecords = try onePassword.fetchLogins(vault: vault)
                let appleRecords = try apple.fetchLogins()
                let plan = SyncPlanner().buildPlan(
                    onePasswordRecords: onePasswordRecords,
                    appleRecords: appleRecords,
                    options: SyncOptions(
                        direction: direction,
                        truthSource: truthSource,
                        conflictPolicy: conflictPolicy,
                        allowPasswordOnlyForUnsupportedSecurityMaterial: allowPasswordOnly
                    )
                )
                return (plan, onePasswordRecords, appleRecords)
            }.value
            livePlan = result.0
            liveSnapshot = (result.1, result.2)
            liveMessage = "Live dry-run plan generated with \(result.0.actions.count) actions. Review before applying."
        } catch {
            liveError = String(describing: error)
        }
    }

    func applyLivePlan() async {
        guard let livePlan else {
            liveError = "Run a live dry-run plan first."
            return
        }
        guard let liveSnapshot else {
            liveError = "Live provider snapshot is missing. Run a live dry-run plan again."
            return
        }
        guard !backupPassphrase.isEmpty else {
            liveError = "Backup passphrase is required before apply."
            return
        }
        guard livePlan.actions.allSatisfy({ $0.kind != .conflict && $0.kind != .unsupported }) else {
            liveError = "Apply is blocked until conflicts and unsupported passkey/TOTP actions are resolved."
            return
        }

        isApplyingLivePlan = true
        liveError = nil
        liveMessage = nil
        let backupPath = backupPath
        let backupPassphrase = backupPassphrase
        let opPath = opPath
        let vault = normalizedVault(liveVault)

        do {
            try await Task.detached {
                try BackupManager().writeEncryptedBackup(
                    payload: BackupPayload(
                        onePasswordRecords: liveSnapshot.onePassword,
                        appleRecords: liveSnapshot.apple,
                        warnings: livePlan.warnings + [
                            "Backup created by PassSync macOS app before live apply.",
                            "Provider-managed passkey private key material is not exportable through these APIs."
                        ]
                    ),
                    passphrase: backupPassphrase,
                    outputPath: backupPath
                )
                let onePassword = OnePasswordClient(runner: ProcessRunner(), opPath: opPath)
                let apple = AppleKeychainClient()
                try SyncExecutor(onePassword: onePassword, applePasswords: apple).apply(
                    plan: livePlan,
                    onePasswordVault: vault
                )
            }.value
            liveMessage = "Sync applied. Encrypted backup written to \(backupPath)."
        } catch {
            liveError = String(describing: error)
        }
        isApplyingLivePlan = false
    }

    func runRestorePlan() async {
        isRunningRestorePlan = true
        restoreError = nil
        restoreMessage = nil
        restorePlan = nil
        defer { isRunningRestorePlan = false }

        guard !restorePassphrase.isEmpty else {
            restoreError = "Backup passphrase is required to read the backup."
            return
        }

        let backupPath = restoreBackupPath
        let passphrase = restorePassphrase
        let target = restoreTarget
        let opPath = opPath
        let vault = normalizedVault(restoreVault)
        let allowPasswordOnly = restoreAllowPasswordOnly

        do {
            let result = try await Task.detached { () throws -> (SyncPlan, [CredentialRecord]) in
                let backup = try BackupManager().readEncryptedBackup(inputPath: backupPath, passphrase: passphrase)
                let current: [CredentialRecord]
                switch target {
                case .onePassword:
                    current = try OnePasswordClient(runner: ProcessRunner(), opPath: opPath).fetchLogins(vault: vault)
                case .applePasswords:
                    current = try AppleKeychainClient().fetchLogins()
                }
                let plan = RestorePlanner().buildPlan(
                    backup: backup,
                    currentRecords: current,
                    target: target,
                    allowPasswordOnlyForUnsupportedSecurityMaterial: allowPasswordOnly
                )
                return (plan, current)
            }.value
            restorePlan = result.0
            restoreSnapshot = result.1
            restoreMessage = "Restore dry-run generated with \(result.0.actions.count) actions."
        } catch {
            restoreError = String(describing: error)
        }
    }

    func applyRestorePlan() async {
        guard let restorePlan else {
            restoreError = "Run a restore dry-run first."
            return
        }
        guard let restoreSnapshot else {
            restoreError = "Current provider snapshot is missing. Run restore dry-run again."
            return
        }
        guard !restorePassphrase.isEmpty else {
            restoreError = "Backup passphrase is required."
            return
        }
        guard restorePlan.actions.allSatisfy({ $0.kind != .conflict && $0.kind != .unsupported }) else {
            restoreError = "Restore is blocked until unsupported actions are resolved."
            return
        }

        isApplyingRestorePlan = true
        restoreError = nil
        restoreMessage = nil
        let target = restoreTarget
        let passphrase = restorePassphrase
        let opPath = opPath
        let vault = normalizedVault(restoreVault)
        let safetyBackupPath = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.passsync/backups/passsync-pre-restore-\(Int(Date().timeIntervalSince1970)).psbackup"

        do {
            try await Task.detached {
                let safetyPayload = BackupPayload(
                    onePasswordRecords: target == .onePassword ? restoreSnapshot : [],
                    appleRecords: target == .applePasswords ? restoreSnapshot : [],
                    warnings: ["Pre-restore safety backup created by PassSync macOS app."]
                )
                try BackupManager().writeEncryptedBackup(payload: safetyPayload, passphrase: passphrase, outputPath: safetyBackupPath)
                let onePassword = OnePasswordClient(runner: ProcessRunner(), opPath: opPath)
                let apple = AppleKeychainClient()
                try SyncExecutor(onePassword: onePassword, applePasswords: apple).apply(
                    plan: restorePlan,
                    onePasswordVault: vault
                )
            }.value
            restoreMessage = "Restore applied. Pre-restore backup written to \(safetyBackupPath)."
        } catch {
            restoreError = String(describing: error)
        }
        isApplyingRestorePlan = false
    }

    private func writeSimulationState(_ state: SimulationState, path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let outputURL = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(state).write(to: outputURL, options: [.atomic])
    }

    private func normalizedVault(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case dashboard
    case simulation
    case livePlan
    case restore
    case conflicts
    case limitations

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard:
            return "Dashboard"
        case .simulation:
            return "Simulation"
        case .livePlan:
            return "Live Plan"
        case .restore:
            return "Restore"
        case .conflicts:
            return "Conflicts"
        case .limitations:
            return "Limitations"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard:
            return "checklist"
        case .simulation:
            return "flask"
        case .livePlan:
            return "key"
        case .restore:
            return "clock.arrow.circlepath"
        case .conflicts:
            return "rectangle.split.2x1"
        case .limitations:
            return "exclamationmark.triangle"
        }
    }
}

enum Loadable<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed(String)
}

struct PreflightReport: Equatable {
    var opPath: String
    var opFound: Bool
    var opVersion: String?
    var keychainAvailable: Bool
    var notes: [String]
}

extension SyncDirection: Identifiable {
    public var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .onePasswordToApple:
            return "1Password to Apple"
        case .appleToOnePassword:
            return "Apple to 1Password"
        case .bidirectional:
            return "Bidirectional"
        }
    }
}

extension TruthSource: Identifiable {
    public var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .none:
            return "No default"
        case .onePassword:
            return "1Password"
        case .applePasswords:
            return "Apple Passwords"
        }
    }
}

extension ConflictPolicy: Identifiable {
    public var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .interactive:
            return "Review manually"
        case .fail:
            return "Fail on conflict"
        case .preferOnePassword:
            return "Prefer 1Password"
        case .preferApple:
            return "Prefer Apple"
        case .preferNewest:
            return "Prefer newest"
        }
    }
}

extension RestoreTarget: Identifiable {
    public var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .onePassword:
            return "1Password"
        case .applePasswords:
            return "Apple Passwords"
        }
    }
}
