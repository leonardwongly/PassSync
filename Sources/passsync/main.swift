import Foundation
import PassSyncCore

@main
struct PassSyncCLI {
    static func main() {
        do {
            try run()
        } catch let error as PassSyncError {
            fputs("passsync: \(error.description)\n", stderr)
            Foundation.exit(2)
        } catch {
            fputs("passsync: \(error)\n", stderr)
            Foundation.exit(2)
        }
    }

    private static func run() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            print(usage)
            return
        }
        args.removeFirst()

        switch command {
        case "help", "--help", "-h":
            print(usage)
        case "version", "--version":
            print("passsync \(PassSyncVersion.current)")
        case "preflight":
            try preflight(args)
        case "doctor":
            try doctor(args)
        case "examples":
            try examples(args)
        case "plan":
            try plan(args, apply: false, requireDirection: true)
        case "sync":
            try plan(args, apply: args.contains("--apply"), requireDirection: true)
        case "simulate":
            try simulate(args, apply: args.contains("--apply"))
        case "backup":
            try backup(args)
        case "backup-list":
            try backupList(args)
        case "backup-migrate":
            try backupMigrate(args)
        case "audit-list":
            try auditList(args)
        case "state-summary":
            try stateSummary(args)
        case "state-list-credentials":
            try stateListCredentials(args)
        case "state-record-simulation":
            try stateRecordSimulation(args)
        case "state-record-decision":
            try stateRecordDecision(args)
        case "state-record-receipt":
            try stateRecordReceipt(args)
        case "restore-check":
            try restoreCheck(args)
        case "restore-verify":
            try restoreVerify(args)
        case "restore-plan":
            try restore(args, apply: false)
        case "restore":
            try restore(args, apply: args.contains("--apply"))
        default:
            throw PassSyncError.invalidArguments("Unknown command \(command).")
        }
    }

    private static func preflight(_ args: [String]) throws {
        let options = try CLIOptions(args: args)
        print("PassSync preflight")
        print("- platform: macOS")
        print("- op path: \(options.opPath)")

        if FileManager.default.isExecutableFile(atPath: options.opPath) {
            print("- 1Password CLI: found")
        } else {
            throw PassSyncError.invalidArguments("1Password CLI not found at \(options.opPath). Use --op-path.")
        }

        let runner = ProcessRunner()
        let result = try runner.run(executable: options.opPath, arguments: ["--version"], stdin: nil)
        if result.status == 0 {
            print("- 1Password CLI version: \(String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown")")
        } else {
            throw PassSyncError.commandFailed(command: "op --version", status: result.status, stderr: String(data: result.stderr, encoding: .utf8) ?? "")
        }

        _ = AppleKeychainClient()
        print("- Apple Keychain API: available")
        print("- passkeys: detection/reporting only unless provider-supported Credential Exchange files are supplied in a future version")
        print("- Apple TOTP writes: not available through Keychain internet-password API; apply will fail closed instead of dropping TOTP")
    }

    private static func doctor(_ args: [String]) throws {
        let options = try CLIOptions(args: args)
        let report = Doctor(runner: ProcessRunner()).run(options: DoctorOptions(
            opPath: options.opPath,
            vault: options.vault,
            backupPath: options.backupPath,
            auditPath: options.auditPath ?? defaultAuditPath(),
            appBundlePath: options.appBundlePath,
            releaseScriptPath: options.releaseScriptPath
        ))
        if options.json {
            printJSON(report)
        } else {
            printDoctorReport(report)
        }
    }

    private static func examples(_ args: [String]) throws {
        var args = args
        let subcommand = args.first ?? "list"
        if !args.isEmpty { args.removeFirst() }

        switch subcommand {
        case "list":
            for example in SimulationExamples.all {
                print("\(example.name): \(example.summary)")
            }
        case "show":
            let name = args.first ?? "bidirectional"
            guard let example = SimulationExamples.named(name) else {
                throw PassSyncError.invalidArguments("Unknown example \(name). Run `passsync examples list`.")
            }
            printJSON(example.state)
        case "write":
            guard let name = args.first else {
                throw PassSyncError.invalidArguments("examples write requires an example name.")
            }
            args.removeFirst()
            guard let example = SimulationExamples.named(name) else {
                throw PassSyncError.invalidArguments("Unknown example \(name). Run `passsync examples list`.")
            }
            let options = try CLIOptions(args: args)
            guard let outputPath = options.outputPath else {
                throw PassSyncError.invalidArguments("examples write requires --output <path>.")
            }
            try writeSimulationState(example.state, path: outputPath)
            print("Wrote \(name) example to \(outputPath).")
        default:
            throw PassSyncError.invalidArguments("Unknown examples subcommand \(subcommand). Use list, show, or write.")
        }
    }

    private static func plan(_ args: [String], apply: Bool, requireDirection: Bool) throws {
        let options = try CLIOptions(args: args)
        if requireDirection, !options.didSetDirection {
            throw PassSyncError.invalidArguments("plan/sync requires --direction 1p-to-apple|apple-to-1p|bidirectional.")
        }
        let syncOptions = SyncOptions(
            direction: options.direction,
            truthSource: options.truthSource,
            conflictPolicy: options.conflictPolicy,
            allowPasswordOnlyForUnsupportedSecurityMaterial: options.allowPasswordOnly
        )

        let onePassword = OnePasswordClient(runner: ProcessRunner(), opPath: options.opPath)
        let apple = AppleKeychainClient()

        let onePasswordRecords = try onePassword.fetchLogins(vault: options.vault)
        let appleRecords = try apple.fetchLogins()
        var syncPlan = SyncPlanner().buildPlan(
            onePasswordRecords: onePasswordRecords,
            appleRecords: appleRecords,
            options: syncOptions
        )
        if let decisionPath = options.decisionFilePath {
            let decisions = try readDecisionFile(path: decisionPath)
            syncPlan = PlanDecisionFiles.apply(
                decisions,
                to: syncPlan,
                allowPasswordOnlyForUnsupportedSecurityMaterial: options.allowPasswordOnly
            )
        }

        if options.json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let redacted = SecretRedactor.redactPlan(syncPlan)
            print(String(data: try encoder.encode(redacted), encoding: .utf8) ?? "{}")
        } else {
            printPlan(syncPlan)
        }

        if let outputPath = options.outputPath {
            try writeDecisionFile(PlanDecisionFiles.export(from: syncPlan), path: outputPath)
            if !options.json {
                print("\nDecision file written: \(outputPath)")
            }
        }

        guard apply else {
            if !options.json {
                print("\nDry run only. Re-run `passsync sync ... --apply` to mutate after reviewing the plan.")
            }
            return
        }

        if options.conflictPolicy == .interactive {
            syncPlan = try resolveInteractiveConflicts(syncPlan, allowPasswordOnly: options.allowPasswordOnly)
        }

        let unsupported = syncPlan.actions.filter { $0.kind == .unsupported }
        guard unsupported.isEmpty else {
            let reasons = unsupported.map { "\($0.key): \($0.reason)" }.joined(separator: "\n")
            throw PassSyncError.unsafeApply("Plan has unsupported passkey/TOTP actions:\n\(reasons)")
        }

        let conflicts = syncPlan.actions.filter { $0.kind == .conflict }
        guard conflicts.isEmpty else {
            let reasons = conflicts.map { "\($0.key): \($0.reason)" }.joined(separator: "\n")
            throw PassSyncError.unsafeApply("Plan has unresolved conflicts:\n\(reasons)")
        }

        let backupPath = options.backupPath ?? defaultBackupPath()
        let passphrase = try readBackupPassphrase()
        let backupPayload = BackupPayload(
            onePasswordRecords: onePasswordRecords,
            appleRecords: appleRecords,
            warnings: syncPlan.warnings + [
                "Backup includes credentials visible to 1Password CLI and macOS Keychain internet-password APIs. Provider-managed passkey private key material is not exportable through these APIs."
            ]
        )
        try BackupManager().writeEncryptedBackup(payload: backupPayload, passphrase: passphrase, outputPath: backupPath)
        print("Encrypted backup written: \(backupPath)")

        let executor = SyncExecutor(onePassword: onePassword, applePasswords: apple)
        try executor.apply(plan: syncPlan, onePasswordVault: options.vault)
        let verification = postApplySyncVerification(
            options: options,
            syncOptions: syncOptions,
            decisionFilePath: options.decisionFilePath
        )
        let receipt = ApplyReceipt(
            operation: .sync,
            backupPath: backupPath,
            decisionFilePath: options.decisionFilePath,
            direction: syncPlan.direction,
            truthSource: syncPlan.truthSource,
            conflictPolicy: syncPlan.conflictPolicy,
            plan: syncPlan,
            postApplyVerification: verification
        )
        let receiptPath = try AuditLog().writeReceipt(receipt, directoryPath: defaultAuditPath())
        print("Sync applied.")
        print("Apply receipt written: \(receiptPath)")
    }

    private static func backup(_ args: [String]) throws {
        let options = try CLIOptions(args: args)
        let output = options.backupPath ?? defaultBackupPath()
        let onePassword = OnePasswordClient(runner: ProcessRunner(), opPath: options.opPath)
        let apple = AppleKeychainClient()
        let payload = BackupPayload(
            onePasswordRecords: try onePassword.fetchLogins(vault: options.vault),
            appleRecords: try apple.fetchLogins(),
            warnings: [
                "Backup includes credentials visible to 1Password CLI and macOS Keychain internet-password APIs. Provider-managed passkey private key material is not exportable through these APIs."
            ]
        )
        let passphrase = try readBackupPassphrase()
        try BackupManager().writeEncryptedBackup(payload: payload, passphrase: passphrase, outputPath: output)
        print("Encrypted backup written: \(output)")
    }

    private static func restoreCheck(_ args: [String]) throws {
        let options = try CLIOptions(args: args)
        guard let path = options.backupPath else {
            throw PassSyncError.invalidArguments("restore-check requires --backup-path <path>.")
        }
        let passphrase = try readBackupPassphrase()
        let payload = try BackupManager().readEncryptedBackup(inputPath: path, passphrase: passphrase)
        print("Backup OK")
        print("- created: \(payload.createdAt)")
        print("- 1Password records: \(payload.onePasswordRecords.count)")
        print("- Apple records: \(payload.appleRecords.count)")
        for warning in payload.warnings {
            print("- warning: \(warning)")
        }
    }

    private static func backupList(_ args: [String]) throws {
        let options = try CLIOptions(args: args)
        let path = options.backupPath ?? defaultBackupDirectory()
        let items = BackupInventory().scan(path: path)
        if options.json {
            printJSON(items)
            return
        }

        print("PassSync backup inventory")
        print("- path: \(path)")
        print("- backups: \(items.count)")
        for item in items {
            if let envelope = item.envelope {
                print("[OK] \(item.path)")
                print("  - size: \(item.fileSize) bytes")
                print("  - modified: \(item.modifiedAt?.description ?? "unknown")")
                print("  - format: \(envelope.format)")
                print("  - kdf: \(envelope.kdf)")
                print("  - iterations: \(envelope.iterations)")
            } else {
                print("[WARN] \(item.path)")
                print("  - error: \(item.error ?? "Could not inspect backup envelope.")")
            }
        }
    }

    private static func auditList(_ args: [String]) throws {
        let options = try CLIOptions(args: args)
        let path = options.inputPath ?? defaultAuditPath()
        let items = AuditInventory().scan(path: path)
        if options.json {
            printJSON(items)
            return
        }

        print("PassSync audit inventory")
        print("- path: \(path)")
        print("- receipts: \(items.count)")
        for item in items {
            if let receipt = item.receipt {
                print("[OK] \(item.path)")
                print("  - operation: \(receipt.operation.rawValue)")
                print("  - created: \(receipt.createdAt)")
                print("  - actions: \(receipt.actionCount)")
                print("  - mutating actions: \(receipt.mutatingActionCount)")
                print("  - backup: \(receipt.backupPath)")
                print("  - sha256: \(item.sha256 ?? "unknown")")
                print("  - previous receipt sha256: \(receipt.previousReceiptSHA256 ?? "none")")
            } else {
                print("[WARN] \(item.path)")
                print("  - error: \(item.error ?? "Could not inspect receipt.")")
            }
        }
    }

    private static func stateSummary(_ args: [String]) throws {
        let options = try CLIOptions(args: args)
        let summary = try stateStore(options).summary()
        if options.json {
            printJSON(summary)
            return
        }

        print("PassSync state store")
        print("- path: \(summary.path)")
        print("- credentials: \(summary.credentialCount)")
        print("- decision files: \(summary.decisionFileCount)")
        print("- receipts: \(summary.receiptCount)")
        print("- latest observation: \(summary.latestObservationAt?.description ?? "none")")
    }

    private static func stateListCredentials(_ args: [String]) throws {
        let options = try CLIOptions(args: args)
        let snapshots = try stateStore(options).credentialSnapshots(limit: options.limit)
        if options.json {
            printJSON(snapshots)
            return
        }

        print("PassSync credential snapshots")
        print("- count: \(snapshots.count)")
        for snapshot in snapshots {
            print("[\(snapshot.provider.rawValue)] \(snapshot.key)")
            print("  - title: \(snapshot.title)")
            print("  - urls: \(snapshot.urlCount)")
            print("  - totp: \(snapshot.hasTOTP)")
            print("  - passkey: \(snapshot.hasPasskey)")
            print("  - observed: \(snapshot.observedAt)")
        }
    }

    private static func stateRecordSimulation(_ args: [String]) throws {
        let options = try CLIOptions(args: args)
        guard let inputPath = options.inputPath else {
            throw PassSyncError.invalidArguments("state-record-simulation requires --input <path>.")
        }

        let state = try readSimulationState(path: inputPath)
        let store = stateStore(options)
        let count = try store.recordCredentials(state.onePasswordRecords + state.appleRecords)
        if options.json {
            printJSON(try store.summary())
        } else {
            print("Recorded \(count) credential snapshot(s) from \(inputPath).")
            print("State store: \(store.path)")
        }
    }

    private static func stateRecordDecision(_ args: [String]) throws {
        let options = try CLIOptions(args: args)
        guard let inputPath = options.inputPath else {
            throw PassSyncError.invalidArguments("state-record-decision requires --input <path>.")
        }

        let store = stateStore(options)
        try store.recordDecisionFile(path: inputPath)
        if options.json {
            printJSON(try store.summary())
        } else {
            print("Recorded decision file metadata from \(inputPath).")
            print("State store: \(store.path)")
        }
    }

    private static func stateRecordReceipt(_ args: [String]) throws {
        let options = try CLIOptions(args: args)
        guard let inputPath = options.inputPath else {
            throw PassSyncError.invalidArguments("state-record-receipt requires --input <path>.")
        }

        let store = stateStore(options)
        try store.recordReceipt(path: inputPath)
        if options.json {
            printJSON(try store.summary())
        } else {
            print("Recorded receipt metadata from \(inputPath).")
            print("State store: \(store.path)")
        }
    }


    private static func backupMigrate(_ args: [String]) throws {
        let options = try CLIOptions(args: args)
        guard let inputPath = options.inputPath else {
            throw PassSyncError.invalidArguments("backup-migrate requires --input <path>.")
        }
        guard let outputPath = options.outputPath else {
            throw PassSyncError.invalidArguments("backup-migrate requires --output <path>.")
        }
        let passphrase = try readBackupPassphrase()
        let info = try BackupManager().migrateEncryptedBackup(
            inputPath: inputPath,
            outputPath: outputPath,
            passphrase: passphrase
        )
        if options.json {
            printJSON(info)
        } else {
            print("Migrated encrypted backup: \(outputPath)")
            print("- format: \(info.format)")
            print("- kdf: \(info.kdf)")
            print("- iterations: \(info.iterations)")
        }
    }

    private static func restoreVerify(_ args: [String]) throws {
        let options = try CLIOptions(args: args)
        guard let path = options.backupPath else {
            throw PassSyncError.invalidArguments("restore-verify requires --backup-path <path>.")
        }
        guard let target = options.restoreTarget else {
            throw PassSyncError.invalidArguments("restore-verify requires --to 1password|apple-passwords.")
        }

        let passphrase = try readBackupPassphrase()
        let backup = try BackupManager().readEncryptedBackup(inputPath: path, passphrase: passphrase)
        let current = try fetchCurrentRecords(target: target, options: options)
        let report = RestoreVerifier().verify(
            backup: backup,
            currentRecords: current,
            target: target,
            allowPasswordOnlyForUnsupportedSecurityMaterial: options.allowPasswordOnly
        )

        if options.json {
            printJSON(report)
        } else {
            printRestoreVerificationReport(report)
        }

        guard report.passed else {
            throw PassSyncError.unsafeApply("Restore verification found \(report.failureCount) mismatch or unsupported record(s).")
        }
    }

    private static func restore(_ args: [String], apply: Bool) throws {
        let options = try CLIOptions(args: args)
        guard let path = options.backupPath else {
            throw PassSyncError.invalidArguments("restore-plan/restore requires --backup-path <path>.")
        }
        guard let target = options.restoreTarget else {
            throw PassSyncError.invalidArguments("restore-plan/restore requires --to 1password|apple-passwords.")
        }

        let passphrase = try readBackupPassphrase()
        let backup = try BackupManager().readEncryptedBackup(inputPath: path, passphrase: passphrase)
        let current = try fetchCurrentRecords(target: target, options: options)
        var restorePlan = RestorePlanner().buildPlan(
            backup: backup,
            currentRecords: current,
            target: target,
            allowPasswordOnlyForUnsupportedSecurityMaterial: options.allowPasswordOnly
        )
        if let decisionPath = options.decisionFilePath {
            let decisions = try readDecisionFile(path: decisionPath)
            restorePlan = PlanDecisionFiles.apply(
                decisions,
                to: restorePlan,
                allowPasswordOnlyForUnsupportedSecurityMaterial: options.allowPasswordOnly
            )
        }

        if options.json {
            printJSON(SecretRedactor.redactPlan(restorePlan))
        } else {
            print("PassSync restore plan")
            print("- target: \(target.rawValue)")
            print("- backup: \(path)")
            printPlan(restorePlan)
        }

        if let outputPath = options.outputPath {
            try writeDecisionFile(PlanDecisionFiles.export(from: restorePlan), path: outputPath)
            if !options.json {
                print("\nDecision file written: \(outputPath)")
            }
        }

        guard apply else {
            if !options.json {
                print("\nDry run only. Re-run `passsync restore ... --apply` after reviewing the plan.")
            }
            return
        }

        if options.conflictPolicy == .interactive {
            restorePlan = try resolveInteractiveConflicts(restorePlan, allowPasswordOnly: options.allowPasswordOnly)
        }

        let unsupported = restorePlan.actions.filter { $0.kind == .unsupported }
        guard unsupported.isEmpty else {
            let reasons = unsupported.map { "\($0.key): \($0.reason)" }.joined(separator: "\n")
            throw PassSyncError.unsafeApply("Restore plan has unsupported actions:\n\(reasons)")
        }

        let conflicts = restorePlan.actions.filter { $0.kind == .conflict }
        guard conflicts.isEmpty else {
            let reasons = conflicts.map { "\($0.key): \($0.reason)" }.joined(separator: "\n")
            throw PassSyncError.unsafeApply("Restore plan has unresolved conflicts:\n\(reasons)")
        }

        let safetyBackupPath = defaultBackupPath()
        let safetyPayload = BackupPayload(
            onePasswordRecords: target == .onePassword ? current : [],
            appleRecords: target == .applePasswords ? current : [],
            warnings: [
                "Pre-restore safety backup created before applying restore from \(path)."
            ]
        )
        try BackupManager().writeEncryptedBackup(payload: safetyPayload, passphrase: passphrase, outputPath: safetyBackupPath)
        print("Pre-restore encrypted backup written: \(safetyBackupPath)")

        let onePassword = OnePasswordClient(runner: ProcessRunner(), opPath: options.opPath)
        let apple = AppleKeychainClient()
        try SyncExecutor(onePassword: onePassword, applePasswords: apple).apply(
            plan: restorePlan,
            onePasswordVault: options.vault
        )
        let verification = postApplyRestoreVerification(
            backup: backup,
            target: target,
            options: options,
            allowPasswordOnly: options.allowPasswordOnly
        )
        let receipt = ApplyReceipt(
            operation: .restore,
            backupPath: path,
            safetyBackupPath: safetyBackupPath,
            decisionFilePath: options.decisionFilePath,
            direction: restorePlan.direction,
            truthSource: restorePlan.truthSource,
            conflictPolicy: restorePlan.conflictPolicy,
            restoreTarget: target,
            plan: restorePlan,
            postApplyVerification: verification
        )
        let receiptPath = try AuditLog().writeReceipt(receipt, directoryPath: defaultAuditPath())
        print("Restore applied.")
        print("Apply receipt written: \(receiptPath)")
    }

    private static func simulate(_ args: [String], apply: Bool) throws {
        let options = try CLIOptions(args: args)
        guard options.didSetDirection else {
            throw PassSyncError.invalidArguments("simulate requires --direction 1p-to-apple|apple-to-1p|bidirectional.")
        }
        guard let inputPath = options.inputPath else {
            throw PassSyncError.invalidArguments("simulate requires --input <path>.")
        }

        let state = try readSimulationState(path: inputPath)
        let store = SimulationStore(state: state)
        let syncOptions = SyncOptions(
            direction: options.direction,
            truthSource: options.truthSource,
            conflictPolicy: options.conflictPolicy,
            allowPasswordOnlyForUnsupportedSecurityMaterial: options.allowPasswordOnly
        )

        var syncPlan = SyncPlanner().buildPlan(
            onePasswordRecords: try store.fetchLogins(vault: options.vault),
            appleRecords: try store.fetchLogins(),
            options: syncOptions
        )
        if let decisionPath = options.decisionFilePath {
            let decisions = try readDecisionFile(path: decisionPath)
            syncPlan = PlanDecisionFiles.apply(
                decisions,
                to: syncPlan,
                allowPasswordOnlyForUnsupportedSecurityMaterial: options.allowPasswordOnly
            )
        }

        if options.json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            print(String(data: try encoder.encode(SecretRedactor.redactPlan(syncPlan)), encoding: .utf8) ?? "{}")
        } else {
            printPlan(syncPlan)
        }

        guard apply else {
            if let outputPath = options.outputPath {
                try writeDecisionFile(PlanDecisionFiles.export(from: syncPlan), path: outputPath)
                if !options.json {
                    print("\nDecision file written: \(outputPath)")
                }
            }
            if !options.json {
                print("\nSimulation dry run only. Re-run with `--apply --output <path>` to write a simulated result state.")
            }
            return
        }

        guard let outputPath = options.outputPath else {
            throw PassSyncError.invalidArguments("simulate --apply requires --output <path>; the input fixture is never modified in place.")
        }

        if options.conflictPolicy == .interactive {
            syncPlan = try resolveInteractiveConflicts(syncPlan, allowPasswordOnly: options.allowPasswordOnly)
        }

        let executor = SyncExecutor(onePassword: store, applePasswords: store)
        try executor.apply(plan: syncPlan, onePasswordVault: options.vault)
        try writeSimulationState(store.state, path: outputPath)
        print("Simulation output written: \(outputPath)")
    }

    private static func printPlan(_ plan: SyncPlan) {
        print("PassSync plan")
        print("- direction: \(plan.direction.rawValue)")
        print("- truth source: \(plan.truthSource.rawValue)")
        print("- conflict policy: \(plan.conflictPolicy.rawValue)")
        print("- actions: \(plan.actions.count)")
        for warning in plan.warnings {
            print("- warning: \(warning)")
        }
        for action in plan.actions {
            print("[\(action.kind.rawValue)] \(action.key) - \(action.reason)")
            printFieldDiffs(for: action)
        }
    }

    private static func printFieldDiffs(for action: SyncAction) {
        guard let source = action.sourceRecord,
              let destination = action.destinationRecord else {
            return
        }
        let diffs = CredentialDiff.fieldDiffs(source: source, destination: destination)
        guard !diffs.isEmpty else { return }
        for diff in diffs {
            print("  - \(diff.field.rawValue): source=\(diff.sourceValue.isEmpty ? "<empty>" : diff.sourceValue), destination=\(diff.destinationValue.isEmpty ? "<empty>" : diff.destinationValue)")
        }
    }

    private static func resolveInteractiveConflicts(_ plan: SyncPlan, allowPasswordOnly: Bool) throws -> SyncPlan {
        var copy = plan
        var resolvedActions: [SyncAction] = []

        for action in plan.actions {
            guard action.kind == .conflict,
                  let sourceRecord = action.sourceRecord,
                  let destinationRecord = action.destinationRecord else {
                resolvedActions.append(action)
                continue
            }

            let onePasswordRecord = sourceRecord.provider == .onePassword ? sourceRecord : destinationRecord
            let appleRecord = sourceRecord.provider == .applePasswords ? sourceRecord : destinationRecord

            print("")
            print("Conflict: \(action.key)")
            print("1Password: title=\"\(onePasswordRecord.title)\", updated=\(onePasswordRecord.modifiedAt?.description ?? "unknown"), passkey=\(onePasswordRecord.hasPasskey), totp=\(onePasswordRecord.totpURI != nil)")
            print("Apple:     title=\"\(appleRecord.title)\", updated=\(appleRecord.modifiedAt?.description ?? "unknown"), passkey=\(appleRecord.hasPasskey), totp=\(appleRecord.totpURI != nil)")
            for diff in CredentialDiff.fieldDiffs(source: onePasswordRecord, destination: appleRecord) {
                print("  - \(diff.field.rawValue): 1Password=\(diff.sourceValue.isEmpty ? "<empty>" : diff.sourceValue), Apple=\(diff.destinationValue.isEmpty ? "<empty>" : diff.destinationValue)")
            }
            print("Choose: [1] use 1Password, [2] use Apple Passwords, [s] skip, [a] abort")

            guard let response = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
                throw PassSyncError.unsafeApply("No interactive conflict response received.")
            }

            switch response {
            case "1":
                if let unsupported = unsupportedInteractiveReason(source: onePasswordRecord, destination: .applePasswords, allowPasswordOnly: allowPasswordOnly) {
                    resolvedActions.append(SyncAction(kind: .unsupported, key: action.key, source: .onePassword, destination: .applePasswords, reason: unsupported, sourceRecord: onePasswordRecord, destinationRecord: appleRecord))
                } else {
                    resolvedActions.append(SyncAction(kind: .updateApple, key: action.key, source: .onePassword, destination: .applePasswords, reason: "Interactive conflict resolved with 1Password.", sourceRecord: onePasswordRecord, destinationRecord: appleRecord))
                }
            case "2":
                if let unsupported = unsupportedInteractiveReason(source: appleRecord, destination: .onePassword, allowPasswordOnly: allowPasswordOnly) {
                    resolvedActions.append(SyncAction(kind: .unsupported, key: action.key, source: .applePasswords, destination: .onePassword, reason: unsupported, sourceRecord: appleRecord, destinationRecord: onePasswordRecord))
                } else {
                    resolvedActions.append(SyncAction(kind: .updateOnePassword, key: action.key, source: .applePasswords, destination: .onePassword, reason: "Interactive conflict resolved with Apple Passwords.", sourceRecord: appleRecord, destinationRecord: onePasswordRecord))
                }
            case "s", "skip":
                resolvedActions.append(SyncAction(kind: .skipIdentical, key: action.key, source: action.source, destination: action.destination, reason: "Interactive conflict skipped.", sourceRecord: sourceRecord, destinationRecord: destinationRecord))
            case "a", "abort":
                throw PassSyncError.unsafeApply("Aborted during interactive conflict resolution.")
            default:
                throw PassSyncError.invalidArguments("Unknown conflict response \(response).")
            }
        }

        copy.actions = resolvedActions
        return copy
    }

    private static func unsupportedInteractiveReason(source: CredentialRecord, destination: Provider, allowPasswordOnly: Bool) -> String? {
        if source.hasPasskey {
            return "Selected source contains passkey evidence; refusing to migrate through password-only APIs."
        }
        if destination == .applePasswords, source.totpURI != nil, !allowPasswordOnly {
            return "Selected source contains a TOTP secret; refusing to drop it when writing to Apple Passwords."
        }
        return nil
    }

    private static func readBackupPassphrase() throws -> String {
        if let value = ProcessInfo.processInfo.environment["PASSSYNC_BACKUP_PASSPHRASE"], !value.isEmpty {
            return value
        }
        guard let first = getpass("Backup passphrase: "), let passphrase = String(validatingCString: first), !passphrase.isEmpty else {
            throw PassSyncError.backupRequired("Missing backup passphrase.")
        }
        guard let second = getpass("Confirm backup passphrase: "), String(validatingCString: second) == passphrase else {
            throw PassSyncError.backupRequired("Backup passphrases did not match.")
        }
        return passphrase
    }

    private static func fetchCurrentRecords(target: RestoreTarget, options: CLIOptions) throws -> [CredentialRecord] {
        switch target {
        case .onePassword:
            return try OnePasswordClient(runner: ProcessRunner(), opPath: options.opPath).fetchLogins(vault: options.vault)
        case .applePasswords:
            return try AppleKeychainClient().fetchLogins()
        }
    }

    private static func printDoctorReport(_ report: DoctorReport) {
        print("PassSync doctor")
        for check in report.checks {
            let mark: String
            switch check.severity {
            case .pass:
                mark = "PASS"
            case .warning:
                mark = "WARN"
            case .fail:
                mark = "FAIL"
            }
            print("[\(mark)] \(check.title): \(check.detail)")
        }
    }

    private static func printRestoreVerificationReport(_ report: RestoreVerificationReport) {
        print("PassSync restore verification")
        print("- target: \(report.target.rawValue)")
        print("- result: \(report.passed ? "passed" : "failed")")
        print("- passed records: \(report.passCount)")
        print("- warnings: \(report.warningCount)")
        print("- failures: \(report.failureCount)")
        for issue in report.issues {
            let mark: String
            switch issue.severity {
            case .pass:
                mark = "PASS"
            case .warning:
                mark = "WARN"
            case .fail:
                mark = "FAIL"
            }
            print("[\(mark)] \(issue.key?.description ?? "provider"): \(issue.title) - \(issue.detail)")
            for diff in issue.fieldDiffs {
                print("  - \(diff.field.rawValue): backup=\(diff.sourceValue.isEmpty ? "<empty>" : diff.sourceValue), current=\(diff.destinationValue.isEmpty ? "<empty>" : diff.destinationValue)")
            }
        }
    }

    private static func printJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(value), let string = String(data: data, encoding: .utf8) {
            print(string)
        } else {
            print("{}")
        }
    }

    private static func defaultBackupPath() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "")
        return "\(defaultBackupDirectory())/passsync-\(stamp).psbackup"
    }

    private static func defaultBackupDirectory() -> String {
        "\(FileManager.default.homeDirectoryForCurrentUser.path)/.passsync/backups"
    }

    private static func defaultAuditPath() -> String {
        "\(FileManager.default.homeDirectoryForCurrentUser.path)/.passsync/audit"
    }

    private static func defaultStatePath() -> String {
        "\(FileManager.default.homeDirectoryForCurrentUser.path)/.passsync/state/passsync.sqlite"
    }

    private static func stateStore(_ options: CLIOptions) -> StateStore {
        StateStore(path: options.statePath ?? defaultStatePath())
    }

    private static func postApplySyncVerification(
        options: CLIOptions,
        syncOptions: SyncOptions,
        decisionFilePath: String?
    ) -> PostApplyVerification {
        do {
            let onePassword = OnePasswordClient(runner: ProcessRunner(), opPath: options.opPath)
            let apple = AppleKeychainClient()
            let onePasswordRecords = try onePassword.fetchLogins(vault: options.vault)
            let appleRecords = try apple.fetchLogins()
            var plan = SyncPlanner().buildPlan(
                onePasswordRecords: onePasswordRecords,
                appleRecords: appleRecords,
                options: syncOptions
            )
            if let decisionFilePath {
                plan = PlanDecisionFiles.apply(
                    try readDecisionFile(path: decisionFilePath),
                    to: plan,
                    allowPasswordOnlyForUnsupportedSecurityMaterial: options.allowPasswordOnly
                )
            }
            return PostApplyVerification(
                mutatingActionCount: plan.mutatingActions.count,
                blockingActionCount: plan.actions.filter { $0.kind == .conflict || $0.kind == .unsupported }.count,
                warningCount: plan.warnings.count,
                notes: ["Post-apply sync verification rebuilt the plan from current provider state."]
            )
        } catch {
            return PostApplyVerification(
                mutatingActionCount: -1,
                blockingActionCount: -1,
                warningCount: 1,
                notes: ["Post-apply sync verification failed: \(error)"]
            )
        }
    }

    private static func postApplyRestoreVerification(
        backup: BackupPayload,
        target: RestoreTarget,
        options: CLIOptions,
        allowPasswordOnly: Bool
    ) -> PostApplyVerification {
        do {
            let current = try fetchCurrentRecords(target: target, options: options)
            let report = RestoreVerifier().verify(
                backup: backup,
                currentRecords: current,
                target: target,
                allowPasswordOnlyForUnsupportedSecurityMaterial: allowPasswordOnly
            )
            return PostApplyVerification(
                mutatingActionCount: report.failureCount,
                blockingActionCount: report.failureCount,
                warningCount: report.warningCount,
                notes: ["Post-apply restore verification \(report.passed ? "passed" : "found restore mismatches")."]
            )
        } catch {
            return PostApplyVerification(
                mutatingActionCount: -1,
                blockingActionCount: -1,
                warningCount: 1,
                notes: ["Post-apply restore verification failed: \(error)"]
            )
        }
    }

    private static func readSimulationState(path: String) throws -> SimulationState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(SimulationState.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            throw PassSyncError.decodingFailed("Could not decode simulation input \(path): \(error)")
        }
    }

    private static func writeSimulationState(_ state: SimulationState, path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let outputURL = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(state).write(to: outputURL, options: [.atomic])
    }

    private static func readDecisionFile(path: String) throws -> PlanDecisionFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(PlanDecisionFile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            throw PassSyncError.decodingFailed("Could not decode decision file \(path): \(error)")
        }
    }

    private static func writeDecisionFile(_ decisions: PlanDecisionFile, path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let outputURL = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(decisions).write(to: outputURL, options: [.atomic])
    }

    private static let usage = """
    passsync - one-time password sync between 1Password and Apple Passwords

    Commands:
      passsync version
      passsync preflight [--op-path PATH]
      passsync doctor [--op-path PATH] [--vault VAULT] [--backup-path PATH] [--app-bundle PATH]
      passsync examples list|show NAME|write NAME --output PATH
      passsync plan --direction 1p-to-apple|apple-to-1p|bidirectional [options]
      passsync sync --direction 1p-to-apple|apple-to-1p|bidirectional [options] [--apply]
      passsync simulate --input PATH --direction 1p-to-apple|apple-to-1p|bidirectional [options] [--apply --output PATH]
      passsync backup [--backup-path PATH] [--vault VAULT]
      passsync backup-list [--backup-path FILE_OR_DIR] [--json]
      passsync backup-migrate --input PATH --output PATH [--json]
      passsync audit-list [--input FILE_OR_DIR] [--json]
      passsync state-summary [--state-path PATH] [--json]
      passsync state-list-credentials [--state-path PATH] [--limit N] [--json]
      passsync state-record-simulation --input PATH [--state-path PATH] [--json]
      passsync state-record-decision --input PATH [--state-path PATH] [--json]
      passsync state-record-receipt --input PATH [--state-path PATH] [--json]
      passsync restore-check --backup-path PATH
      passsync restore-verify --backup-path PATH --to 1password|apple-passwords [options]
      passsync restore-plan --backup-path PATH --to 1password|apple-passwords [options]
      passsync restore --backup-path PATH --to 1password|apple-passwords [options] [--apply]

    Options:
      --direction VALUE          Required for plan/sync.
      --truth-source VALUE       none|1password|apple-passwords. Default: none.
      --conflicts VALUE          interactive|fail|prefer-1password|prefer-apple|prefer-newest. Default: interactive.
      --vault VALUE              1Password vault name or ID.
      --backup-path PATH         Encrypted backup path. Required for restore-check; defaulted for backup/apply.
      --audit-path PATH          Audit receipt directory for doctor checks.
      --state-path PATH          Durable non-secret SQLite state store path.
      --to VALUE                 Restore target: 1password|apple-passwords.
      --input PATH               Simulation input state JSON or backup-migrate source.
      --output PATH              Simulation apply output, backup-migrate destination, or dry-run decision-file export path.
      --decision-file PATH       Apply reviewed decisions from a decision file to a freshly built plan or simulation.
      --app-bundle PATH          App bundle path for doctor checks.
      --release-script PATH      Release script path for doctor checks.
      --limit N                  Maximum credential snapshots for state-list-credentials. Default: 100.
      --op-path PATH             Path to op. Default: /opt/homebrew/bin/op.
      --json                     Print redacted JSON plan.
      --allow-password-only-for-unsupported-security-material
                                 Allow password-only writes when Apple cannot accept TOTP/passkey material.
      --apply                    Mutate. Without --apply, sync is a dry run.

    Security defaults:
      - Dry-run by default.
      - Encrypted backup is written before every apply.
      - Secrets are redacted from plans.
      - Passkey-bearing records and Apple-destination TOTP records fail closed unless explicitly allowed.
    """
}

private struct CLIOptions {
    var direction: SyncDirection = .bidirectional
    var truthSource: TruthSource = .none
    var conflictPolicy: ConflictPolicy = .interactive
    var vault: String?
    var backupPath: String?
    var auditPath: String?
    var statePath: String?
    var restoreTarget: RestoreTarget?
    var inputPath: String?
    var outputPath: String?
    var decisionFilePath: String?
    var appBundlePath: String?
    var releaseScriptPath: String?
    var opPath = "/opt/homebrew/bin/op"
    var json = false
    var allowPasswordOnly = false
    var didSetDirection = false
    var limit = 100

    init(args: [String]) throws {
        var index = args.startIndex
        while index < args.endIndex {
            let arg = args[index]
            switch arg {
            case "--direction":
                direction = try Self.value(after: arg, in: args, index: &index).parse(SyncDirection.self)
                didSetDirection = true
            case "--truth-source":
                truthSource = try Self.value(after: arg, in: args, index: &index).parse(TruthSource.self)
            case "--conflicts":
                conflictPolicy = try Self.value(after: arg, in: args, index: &index).parse(ConflictPolicy.self)
            case "--vault":
                vault = try Self.value(after: arg, in: args, index: &index)
            case "--backup-path":
                backupPath = try Self.value(after: arg, in: args, index: &index)
            case "--audit-path":
                auditPath = try Self.value(after: arg, in: args, index: &index)
            case "--state-path":
                statePath = try Self.value(after: arg, in: args, index: &index)
            case "--to":
                restoreTarget = try Self.value(after: arg, in: args, index: &index).parse(RestoreTarget.self)
            case "--input":
                inputPath = try Self.value(after: arg, in: args, index: &index)
            case "--output":
                outputPath = try Self.value(after: arg, in: args, index: &index)
            case "--decision-file":
                decisionFilePath = try Self.value(after: arg, in: args, index: &index)
            case "--app-bundle":
                appBundlePath = try Self.value(after: arg, in: args, index: &index)
            case "--release-script":
                releaseScriptPath = try Self.value(after: arg, in: args, index: &index)
            case "--limit":
                let value = try Self.value(after: arg, in: args, index: &index)
                guard let parsed = Int(value), parsed > 0 else {
                    throw PassSyncError.invalidArguments("--limit requires a positive integer.")
                }
                limit = parsed
            case "--op-path":
                opPath = try Self.value(after: arg, in: args, index: &index)
            case "--json":
                json = true
            case "--allow-password-only-for-unsupported-security-material":
                allowPasswordOnly = true
            case "--apply":
                break
            default:
                throw PassSyncError.invalidArguments("Unknown option \(arg).")
            }
            index = args.index(after: index)
        }
    }

    private static func value(after option: String, in args: [String], index: inout Array<String>.Index) throws -> String {
        let valueIndex = args.index(after: index)
        guard valueIndex < args.endIndex else {
            throw PassSyncError.invalidArguments("\(option) requires a value.")
        }
        index = valueIndex
        return args[valueIndex]
    }
}

private extension String {
    func parse<T: RawRepresentable>(_ type: T.Type) throws -> T where T.RawValue == String {
        guard let parsed = T(rawValue: self) else {
            throw PassSyncError.invalidArguments("Invalid \(type) value: \(self).")
        }
        return parsed
    }
}
