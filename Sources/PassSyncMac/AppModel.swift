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
    @Published var conflictReviewMessage: String?
    @Published var conflictReviewError: String?
    @Published var recoveryMessage: String?
    @Published var recoveryError: String?
    @Published var backupInventory: [BackupInventoryItem] = []
    @Published var auditInventory: [AuditInventoryItem] = []
    @Published var isRunningSimulation = false
    @Published var isRunningLivePlan = false
    @Published var isApplyingLivePlan = false
    @Published var isRunningRestorePlan = false
    @Published var isApplyingRestorePlan = false
    @Published var isLoadingDecisionFile = false
    @Published var isSavingDecisionFile = false
    @Published var isScanningBackups = false
    @Published var isScanningAudits = false

    @Published var simulationDirection: SyncDirection = .bidirectional
    @Published var simulationTruthSource: TruthSource = .none
    @Published var simulationConflictPolicy: ConflictPolicy = .interactive
    @Published var simulationVault = "PassSync-Test"
    @Published var simulationAllowPasswordOnly = false
    @Published var simulationOutputPath = AppModel.defaultPrivateOutputPath(directory: "simulations", prefix: "passsync-sim-output", extension: "json")

    @Published var liveDirection: SyncDirection = .bidirectional
    @Published var liveTruthSource: TruthSource = .none
    @Published var liveConflictPolicy: ConflictPolicy = .interactive
    @Published var liveVault = ""
    @Published var liveAllowPasswordOnly = false
    @Published var opPath = "/opt/homebrew/bin/op"
    @Published var backupPath = AppModel.defaultBackupPath(prefix: "passsync-app")
    @Published var backupPassphrase = ""

    @Published var restoreBackupPath = AppModel.defaultBackupPath(prefix: "passsync-app")
    @Published var restoreTarget: RestoreTarget = .onePassword
    @Published var restoreVault = ""
    @Published var restorePassphrase = ""
    @Published var restoreAllowPasswordOnly = false
    @Published var decisionOutputPath = AppModel.defaultPrivateOutputPath(directory: "decisions", prefix: "passsync-decisions", extension: "json")
    @Published var decisionInputPath = AppModel.defaultPrivateOutputPath(directory: "decisions", prefix: "passsync-decisions", extension: "json")
    @Published var decisionPlanTarget: DecisionPlanTarget = .live
    @Published var loadedDecisionFile: PlanDecisionFile?
    @Published var backupInventoryPath = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.passsync/backups"
    @Published var auditInventoryPath = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.passsync/audit"

    private var liveSnapshot: (onePassword: [CredentialRecord], apple: [CredentialRecord])?
    private var restoreSnapshot: [CredentialRecord]?
    private var livePlanContext: LivePlanContext?
    private var restorePlanContext: RestorePlanContext?

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
            try SyncExecutor(
                onePassword: store,
                applePasswords: store,
                allowPasswordOnlyForUnsupportedSecurityMaterial: simulationAllowPasswordOnly
            ).apply(
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
        let context = LivePlanContext(
            direction: direction,
            truthSource: truthSource,
            conflictPolicy: conflictPolicy,
            vault: vault,
            opPath: opPath,
            backupPath: backupPath,
            allowPasswordOnly: allowPasswordOnly
        )

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
            livePlanContext = context
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
        guard let livePlanContext else {
            liveError = "Live plan settings are missing. Run a live dry-run plan again."
            return
        }
        guard currentLivePlanContext() == livePlanContext else {
            liveError = "Live settings changed after the dry-run plan. Run a new dry plan before applying."
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
        let backupPath = livePlanContext.backupPath
        let backupPassphrase = backupPassphrase
        let opPath = livePlanContext.opPath
        let vault = livePlanContext.vault
        let allowPasswordOnly = livePlanContext.allowPasswordOnly

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
                try SyncExecutor(
                    onePassword: onePassword,
                    applePasswords: apple,
                    allowPasswordOnlyForUnsupportedSecurityMaterial: allowPasswordOnly
                ).apply(
                    plan: livePlan,
                    onePasswordVault: vault
                )
            }.value
            liveMessage = "Sync applied. Encrypted backup written to \(backupPath)."
            restoreBackupPath = backupPath
            self.backupPath = Self.defaultBackupPath(prefix: "passsync-app")
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
        let context = RestorePlanContext(
            backupPath: backupPath,
            target: target,
            vault: vault,
            opPath: opPath,
            allowPasswordOnly: allowPasswordOnly
        )

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
            restorePlanContext = context
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
        guard let restorePlanContext else {
            restoreError = "Restore plan settings are missing. Run restore dry-run again."
            return
        }
        guard currentRestorePlanContext() == restorePlanContext else {
            restoreError = "Restore settings changed after the dry-run plan. Run a new restore dry-run before applying."
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
        let target = restorePlanContext.target
        let passphrase = restorePassphrase
        let opPath = restorePlanContext.opPath
        let vault = restorePlanContext.vault
        let allowPasswordOnly = restorePlanContext.allowPasswordOnly
        let safetyBackupPath = Self.defaultBackupPath(prefix: "passsync-pre-restore")

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
                try SyncExecutor(
                    onePassword: onePassword,
                    applePasswords: apple,
                    allowPasswordOnlyForUnsupportedSecurityMaterial: allowPasswordOnly
                ).apply(
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

    func exportLatestDecisionFile() async {
        guard let plan = livePlan ?? simulationPlan ?? restorePlan else {
            conflictReviewError = "Run a simulation, live plan, or restore plan first."
            return
        }

        let outputPath = decisionOutputPath
        isSavingDecisionFile = true
        defer { isSavingDecisionFile = false }
        do {
            let decisionCount = try await Task.detached(priority: .userInitiated) { () throws -> Int in
                let decisions = PlanDecisionFiles.export(from: plan)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let outputURL = URL(fileURLWithPath: outputPath)
                try SecureFileIO.writePrivateData(try encoder.encode(decisions), to: outputURL)
                return decisions.decisions.count
            }.value
            conflictReviewError = nil
            conflictReviewMessage = "Decision file with \(decisionCount) decision(s) written to \(outputPath)."
        } catch {
            conflictReviewMessage = nil
            conflictReviewError = String(describing: error)
        }
    }

    func loadDecisionFile() async {
        let inputPath = decisionInputPath
        isLoadingDecisionFile = true
        defer { isLoadingDecisionFile = false }
        do {
            let file = try await Task.detached(priority: .userInitiated) { () throws -> PlanDecisionFile in
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode(
                    PlanDecisionFile.self,
                    from: Data(contentsOf: URL(fileURLWithPath: inputPath))
                )
            }.value
            loadedDecisionFile = file
            conflictReviewError = nil
            conflictReviewMessage = "Loaded \(file.decisions.count) decision(s) from \(inputPath)."
        } catch {
            conflictReviewMessage = nil
            conflictReviewError = "Could not load decision file: \(error)"
        }
    }

    func saveLoadedDecisionFile() async {
        guard let loadedDecisionFile else {
            conflictReviewError = "Load or export a decision file first."
            return
        }
        let outputPath = decisionOutputPath
        isSavingDecisionFile = true
        defer { isSavingDecisionFile = false }
        do {
            try await Task.detached(priority: .userInitiated) {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let outputURL = URL(fileURLWithPath: outputPath)
                try SecureFileIO.writePrivateData(try encoder.encode(loadedDecisionFile), to: outputURL)
            }.value
            conflictReviewError = nil
            conflictReviewMessage = "Saved edited decision file to \(outputPath)."
        } catch {
            conflictReviewMessage = nil
            conflictReviewError = "Could not save decision file: \(error)"
        }
    }

    func applyLoadedDecisionFileToSelectedPlan() {
        guard let loadedDecisionFile else {
            conflictReviewError = "Load or export a decision file first."
            return
        }

        switch decisionPlanTarget {
        case .simulation:
            guard let simulationPlan else {
                conflictReviewError = "Run a simulation plan before applying decisions to it."
                return
            }
            self.simulationPlan = PlanDecisionFiles.apply(
                loadedDecisionFile,
                to: simulationPlan,
                allowPasswordOnlyForUnsupportedSecurityMaterial: simulationAllowPasswordOnly
            )
        case .live:
            guard let livePlan else {
                conflictReviewError = "Run a live plan before applying decisions to it."
                return
            }
            self.livePlan = PlanDecisionFiles.apply(
                loadedDecisionFile,
                to: livePlan,
                allowPasswordOnlyForUnsupportedSecurityMaterial: liveAllowPasswordOnly
            )
        case .restore:
            guard let restorePlan else {
                conflictReviewError = "Run a restore plan before applying decisions to it."
                return
            }
            self.restorePlan = PlanDecisionFiles.apply(
                loadedDecisionFile,
                to: restorePlan,
                allowPasswordOnlyForUnsupportedSecurityMaterial: restoreAllowPasswordOnly
            )
        }

        conflictReviewError = nil
        conflictReviewMessage = "Applied reviewed decisions to the \(decisionPlanTarget.displayTitle) plan. Review the adjusted plan before applying."
    }

    func setDecisionKind(actionID: String, kind: PlanDecisionKind) {
        guard var file = loadedDecisionFile,
              let index = file.decisions.firstIndex(where: { $0.id == actionID }) else {
            return
        }
        file.decisions[index].decision = kind
        loadedDecisionFile = file
    }

    func setFieldDecision(actionID: String, field: CredentialField, provider: Provider) {
        guard var file = loadedDecisionFile,
              let actionIndex = file.decisions.firstIndex(where: { $0.id == actionID }) else {
            return
        }
        if let fieldIndex = file.decisions[actionIndex].fieldDecisions.firstIndex(where: { $0.field == field }) {
            file.decisions[actionIndex].fieldDecisions[fieldIndex].provider = provider
        } else {
            file.decisions[actionIndex].fieldDecisions.append(PlanFieldDecision(field: field, provider: provider))
        }
        loadedDecisionFile = file
    }

    func loadBackupInventory() async {
        let path = backupInventoryPath
        isScanningBackups = true
        defer { isScanningBackups = false }
        let items = await Task.detached(priority: .userInitiated) {
            BackupInventory().scan(path: path)
        }.value
        backupInventory = items
        recoveryError = nil
        recoveryMessage = "Found \(items.count) backup item(s)."
    }

    func loadAuditInventory() async {
        let path = auditInventoryPath
        isScanningAudits = true
        defer { isScanningAudits = false }
        let items = await Task.detached(priority: .userInitiated) {
            AuditInventory().scan(path: path)
        }.value
        auditInventory = items
        recoveryError = nil
        recoveryMessage = "Found \(items.count) audit receipt item(s)."
    }

    private func writeSimulationState(_ state: SimulationState, path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let outputURL = URL(fileURLWithPath: path)
        try SecureFileIO.writePrivateData(try encoder.encode(state), to: outputURL)
    }

    private func normalizedVault(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func currentLivePlanContext() -> LivePlanContext {
        LivePlanContext(
            direction: liveDirection,
            truthSource: liveTruthSource,
            conflictPolicy: liveConflictPolicy,
            vault: normalizedVault(liveVault),
            opPath: opPath,
            backupPath: backupPath,
            allowPasswordOnly: liveAllowPasswordOnly
        )
    }

    private func currentRestorePlanContext() -> RestorePlanContext {
        RestorePlanContext(
            backupPath: restoreBackupPath,
            target: restoreTarget,
            vault: normalizedVault(restoreVault),
            opPath: opPath,
            allowPasswordOnly: restoreAllowPasswordOnly
        )
    }

    private static func defaultBackupPath(prefix: String) -> String {
        defaultPrivateOutputPath(directory: "backups", prefix: prefix, extension: "psbackup")
    }

    private static func defaultPrivateOutputPath(directory: String, prefix: String, extension: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "")
        let suffix = UUID().uuidString.prefix(8)
        return "\(defaultPrivateDirectory())/\(directory)/\(prefix)-\(stamp)-\(suffix).\(`extension`)"
    }

    private static func defaultPrivateDirectory() -> String {
        "\(FileManager.default.homeDirectoryForCurrentUser.path)/.passsync"
    }
}

private struct LivePlanContext: Equatable {
    var direction: SyncDirection
    var truthSource: TruthSource
    var conflictPolicy: ConflictPolicy
    var vault: String?
    var opPath: String
    var backupPath: String
    var allowPasswordOnly: Bool
}

private struct RestorePlanContext: Equatable {
    var backupPath: String
    var target: RestoreTarget
    var vault: String?
    var opPath: String
    var allowPasswordOnly: Bool
}

enum DecisionPlanTarget: String, CaseIterable, Identifiable {
    case simulation
    case live
    case restore

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .simulation:
            return "Simulation"
        case .live:
            return "Live"
        case .restore:
            return "Restore"
        }
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case dashboard
    case simulation
    case livePlan
    case restore
    case recovery
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
        case .recovery:
            return "Recovery"
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
        case .recovery:
            return "externaldrive.badge.checkmark"
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

extension PlanDecisionKind: Identifiable {
    public var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .applyOriginal:
            return "Apply Original"
        case .skip:
            return "Skip"
        case .useOnePassword:
            return "Use 1Password"
        case .useApplePasswords:
            return "Use Apple"
        case .mergeFields:
            return "Merge Fields"
        }
    }
}

extension Provider: Identifiable {
    public var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .onePassword:
            return "1Password"
        case .applePasswords:
            return "Apple"
        }
    }
}
