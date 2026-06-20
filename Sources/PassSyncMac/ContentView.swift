import PassSyncCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $model.selectedSection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationTitle("PassSync")
        } detail: {
            switch model.selectedSection {
            case .dashboard:
                DashboardView()
            case .simulation:
                SimulationView()
            case .livePlan:
                LivePlanView()
            case .restore:
                RestoreView()
            case .recovery:
                RecoveryView()
            case .conflicts:
                ConflictReviewView()
            case .limitations:
                LimitationsView()
            }
        }
    }
}

private struct DashboardView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HeaderView(
                    title: "PassSync",
                    subtitle: "One-time credential planning and sync for 1Password and Apple Passwords."
                )

                HStack(spacing: 12) {
                    PrimaryButton(title: "Run Preflight", systemImage: "checkmark.shield") {
                        Task { await model.runPreflight() }
                    }
                    Button {
                        model.selectedSection = .simulation
                    } label: {
                        Label("Open Simulation", systemImage: "flask")
                    }
                }

                StatusPanel()
                SafetySummary()
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .task {
            if case .idle = model.preflight {
                await model.runPreflight()
            }
        }
    }
}

private struct StatusPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GroupBox("Preflight") {
            switch model.preflight {
            case .idle:
                Text("Preflight has not run.")
                    .foregroundStyle(.secondary)
            case .loading:
                HStack {
                    ProgressView()
                    Text("Checking local setup...")
                }
            case .loaded(let report):
                VStack(alignment: .leading, spacing: 10) {
                    StatusRow(title: "1Password CLI", value: report.opFound ? "Found at \(report.opPath)" : "Not found", isGood: report.opFound)
                    StatusRow(title: "op version", value: report.opVersion ?? "Unknown", isGood: report.opVersion != nil)
                    StatusRow(title: "Apple Keychain API", value: report.keychainAvailable ? "Available" : "Unavailable", isGood: report.keychainAvailable)
                    ForEach(report.notes, id: \.self) { note in
                        Label(note, systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct SafetySummary: View {
    var body: some View {
        GroupBox("Safety Defaults") {
            VStack(alignment: .leading, spacing: 10) {
                Label("Live sync starts as a dry-run plan.", systemImage: "eye")
                Label("Apply requires an encrypted backup passphrase.", systemImage: "lock")
                Label("Passkey and unsupported TOTP migrations stay blocked.", systemImage: "exclamationmark.triangle")
                Label("Simulation runs without touching real providers.", systemImage: "flask")
            }
            .foregroundStyle(.secondary)
        }
    }
}

private struct SimulationView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            FormPanel(title: "Simulation") {
                Picker("Direction", selection: $model.simulationDirection) {
                    ForEach(SyncDirection.allCases) { direction in
                        Text(direction.displayTitle).tag(direction)
                    }
                }
                Picker("Truth source", selection: $model.simulationTruthSource) {
                    ForEach(TruthSource.allCases) { source in
                        Text(source.displayTitle).tag(source)
                    }
                }
                Picker("Conflicts", selection: $model.simulationConflictPolicy) {
                    ForEach(ConflictPolicy.allCases) { policy in
                        Text(policy.displayTitle).tag(policy)
                    }
                }
                TextField("Vault", text: $model.simulationVault)
                Toggle("Allow password-only Apple writes for unsupported TOTP", isOn: $model.simulationAllowPasswordOnly)
                TextField("Output path", text: $model.simulationOutputPath)

                HStack {
                    PrimaryButton(title: model.isRunningSimulation ? "Planning..." : "Run Simulation", systemImage: "play") {
                        Task { await model.runSimulationPlan() }
                    }
                    .disabled(model.isRunningSimulation)
                    Button {
                        Task { await model.writeSimulationOutput() }
                    } label: {
                        Label("Write Output", systemImage: "square.and.arrow.down")
                    }
                    .disabled(model.simulationPlan == nil)
                }
            }

            PlanResultsView(plan: model.simulationPlan, message: model.simulationMessage)
        }
    }
}

private struct LivePlanView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            FormPanel(title: "Live Providers") {
                Picker("Direction", selection: $model.liveDirection) {
                    ForEach(SyncDirection.allCases) { direction in
                        Text(direction.displayTitle).tag(direction)
                    }
                }
                Picker("Truth source", selection: $model.liveTruthSource) {
                    ForEach(TruthSource.allCases) { source in
                        Text(source.displayTitle).tag(source)
                    }
                }
                Picker("Conflicts", selection: $model.liveConflictPolicy) {
                    ForEach(ConflictPolicy.allCases) { policy in
                        Text(policy.displayTitle).tag(policy)
                    }
                }
                TextField("1Password vault", text: $model.liveVault)
                TextField("op path", text: $model.opPath)
                Toggle("Allow password-only Apple writes for unsupported TOTP", isOn: $model.liveAllowPasswordOnly)
                TextField("Backup path", text: $model.backupPath)
                SecureField("Backup passphrase", text: $model.backupPassphrase)

                HStack {
                    PrimaryButton(title: model.isRunningLivePlan ? "Planning..." : "Run Dry Plan", systemImage: "doc.text.magnifyingglass") {
                        Task { await model.runLivePlan() }
                    }
                    .disabled(model.isRunningLivePlan || model.isApplyingLivePlan)

                    Button(role: .destructive) {
                        Task { await model.applyLivePlan() }
                    } label: {
                        Label(model.isApplyingLivePlan ? "Applying..." : "Apply Reviewed Plan", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(!canApply)
                    .accessibilityHint(applyBlockReason ?? "Apply the reviewed live plan after writing an encrypted backup.")
                }

                if let applyBlockReason {
                    Label(applyBlockReason, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = model.liveError {
                MessageBanner(message: error, style: .error)
            }

            PlanResultsView(plan: model.livePlan, message: model.liveMessage)
        }
    }

    private var canApply: Bool {
        applyBlockReason == nil
    }

    private var applyBlockReason: String? {
        if model.isRunningLivePlan {
            return "Wait for the dry plan to finish before applying."
        }
        if model.isApplyingLivePlan {
            return "The reviewed plan is already applying."
        }
        guard let plan = model.livePlan else {
            return "Run a dry plan before applying."
        }
        if model.backupPassphrase.isEmpty {
            return "Enter a backup passphrase before applying."
        }
        let conflictCount = plan.actions.filter { $0.kind == .conflict }.count
        if conflictCount > 0 {
            return "Resolve \(conflictCount) conflict\(conflictCount == 1 ? "" : "s") before applying."
        }
        let unsupportedCount = plan.actions.filter { $0.kind == .unsupported }.count
        if unsupportedCount > 0 {
            return "Unsupported passkey or TOTP actions block apply."
        }
        return nil
    }
}

private struct RestoreView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            FormPanel(title: "Restore") {
                TextField("Backup path", text: $model.restoreBackupPath)
                SecureField("Backup passphrase", text: $model.restorePassphrase)
                Picker("Restore target", selection: $model.restoreTarget) {
                    ForEach(RestoreTarget.allCases) { target in
                        Text(target.displayTitle).tag(target)
                    }
                }
                TextField("1Password vault", text: $model.restoreVault)
                TextField("op path", text: $model.opPath)
                Toggle("Allow password-only Apple writes for unsupported TOTP", isOn: $model.restoreAllowPasswordOnly)

                HStack {
                    PrimaryButton(title: model.isRunningRestorePlan ? "Planning..." : "Run Restore Plan", systemImage: "clock.arrow.circlepath") {
                        Task { await model.runRestorePlan() }
                    }
                    .disabled(model.isRunningRestorePlan || model.isApplyingRestorePlan)

                    Button(role: .destructive) {
                        Task { await model.applyRestorePlan() }
                    } label: {
                        Label(model.isApplyingRestorePlan ? "Restoring..." : "Apply Restore", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(!canApply)
                    .accessibilityHint(applyBlockReason ?? "Apply the reviewed restore plan after writing an encrypted backup.")
                }

                if let applyBlockReason {
                    Label(applyBlockReason, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = model.restoreError {
                MessageBanner(message: error, style: .error)
            }

            PlanResultsView(plan: model.restorePlan, message: model.restoreMessage)
        }
    }

    private var canApply: Bool {
        applyBlockReason == nil
    }

    private var applyBlockReason: String? {
        if model.isRunningRestorePlan {
            return "Wait for the restore plan to finish before applying."
        }
        if model.isApplyingRestorePlan {
            return "The restore plan is already applying."
        }
        guard let plan = model.restorePlan else {
            return "Run a restore plan before applying."
        }
        if model.restorePassphrase.isEmpty {
            return "Enter the backup passphrase before applying."
        }
        let conflictCount = plan.actions.filter { $0.kind == .conflict }.count
        if conflictCount > 0 {
            return "Resolve \(conflictCount) restore conflict\(conflictCount == 1 ? "" : "s") before applying."
        }
        let unsupportedCount = plan.actions.filter { $0.kind == .unsupported }.count
        if unsupportedCount > 0 {
            return "Unsupported passkey or TOTP restore actions block apply."
        }
        return nil
    }
}

private struct ConflictReviewView: View {
    @EnvironmentObject private var model: AppModel

    private var reviewActions: [SyncAction] {
        let plans = [model.livePlan, model.simulationPlan, model.restorePlan].compactMap { $0 }
        return plans
            .flatMap(\.actions)
            .filter { $0.sourceRecord != nil && $0.destinationRecord != nil }
            .filter {
                switch $0.kind {
                case .conflict, .updateOnePassword, .updateApple, .unsupported:
                    return true
                case .createInOnePassword, .createInApple, .skipIdentical:
                    return false
                }
            }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HeaderView(
                    title: "Conflict Review",
                    subtitle: "Field-level differences from the latest simulation, live, and restore plans."
                )

                GroupBox("Decision File") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Target plan", selection: $model.decisionPlanTarget) {
                            ForEach(DecisionPlanTarget.allCases) { target in
                                Text(target.displayTitle).tag(target)
                            }
                        }
                        TextField("Decision input path", text: $model.decisionInputPath)
                        TextField("Decision output path", text: $model.decisionOutputPath)
                        HStack {
                            Button {
                                model.loadDecisionFile()
                            } label: {
                                Label("Load", systemImage: "folder")
                            }
                            Button {
                                model.exportLatestDecisionFile()
                            } label: {
                                Label("Export", systemImage: "square.and.arrow.down")
                            }
                            .disabled(model.livePlan == nil && model.simulationPlan == nil && model.restorePlan == nil)
                            Button {
                                model.saveLoadedDecisionFile()
                            } label: {
                                Label("Save", systemImage: "square.and.arrow.down.on.square")
                            }
                            .disabled(model.loadedDecisionFile == nil)
                            Button {
                                model.applyLoadedDecisionFileToSelectedPlan()
                            } label: {
                                Label("Apply to Plan", systemImage: "checkmark.rectangle.stack")
                            }
                            .disabled(model.loadedDecisionFile == nil)
                        }
                    }
                }

                if let message = model.conflictReviewMessage {
                    MessageBanner(message: message, style: .info)
                }

                if let error = model.conflictReviewError {
                    MessageBanner(message: error, style: .error)
                }

                if reviewActions.isEmpty {
                    ContentUnavailableView(
                        "No Field Differences",
                        systemImage: "rectangle.split.2x1",
                        description: Text("Run a simulation, live plan, or restore plan to inspect conflicts and updates.")
                    )
                } else {
                    ForEach(reviewActions, id: \.key) { action in
                        ConflictDiffPanel(action: action)
                    }
                }

                if let decisionFile = model.loadedDecisionFile {
                    DecisionFileEditor(file: decisionFile)
                }
            }
            .padding(28)
            .frame(maxWidth: 1040, alignment: .leading)
        }
    }
}

private struct DecisionFileEditor: View {
    @EnvironmentObject private var model: AppModel
    var file: PlanDecisionFile

    var body: some View {
        GroupBox("Loaded Decisions") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(file.format, systemImage: "doc.badge.gearshape")
                    Spacer()
                    Text("\(file.decisions.count) decision\(file.decisions.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                }

                ForEach(file.decisions) { decision in
                    DecisionEditorRow(decision: decision)
                    Divider()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DecisionEditorRow: View {
    @EnvironmentObject private var model: AppModel
    var decision: PlanActionDecision

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(decision.key.description)
                        .font(.headline)
                    Text(decision.originalKind.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Decision", selection: Binding(
                    get: { decision.decision },
                    set: { model.setDecisionKind(actionID: decision.id, kind: $0) }
                )) {
                    ForEach(PlanDecisionKind.allCases) { kind in
                        Text(kind.displayTitle).tag(kind)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("Decision for \(decision.key.description)")
                .accessibilityHint("Select how PassSync handles this reviewed action.")
                .frame(maxWidth: 220)
            }

            if !decision.fieldDecisions.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Field").font(.caption.weight(.semibold))
                        Text("Provider").font(.caption.weight(.semibold))
                    }
                    ForEach(decision.fieldDecisions) { fieldDecision in
                        GridRow {
                            Text(fieldDecision.field.rawValue)
                                .foregroundStyle(.secondary)
                            Picker("Provider", selection: Binding(
                                get: { fieldDecision.provider },
                                set: { model.setFieldDecision(actionID: decision.id, field: fieldDecision.field, provider: $0) }
                            )) {
                                ForEach(Provider.allCases) { provider in
                                    Text(provider.displayTitle).tag(provider)
                                }
                            }
                            .labelsHidden()
                            .accessibilityLabel("Provider for \(fieldDecision.field.rawValue) on \(decision.key.description)")
                            .accessibilityHint("Choose which provider supplies this field.")
                            .frame(maxWidth: 180)
                        }
                    }
                }
                .font(.subheadline)
            }
        }
    }
}

private struct RecoveryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HeaderView(
                    title: "Recovery",
                    subtitle: "Backup inventory and restore evidence from local PassSync files."
                )

                GroupBox("Backup Inventory") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Backup path", text: $model.backupInventoryPath)
                        Button {
                            model.loadBackupInventory()
                        } label: {
                            Label("Scan Backups", systemImage: "externaldrive.badge.magnifyingglass")
                        }
                    }
                }

                GroupBox("Audit Receipts") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Audit path", text: $model.auditInventoryPath)
                        Button {
                            model.loadAuditInventory()
                        } label: {
                            Label("Scan Receipts", systemImage: "list.bullet.rectangle")
                        }
                    }
                }

                if let message = model.recoveryMessage {
                    MessageBanner(message: message, style: .info)
                }

                if let error = model.recoveryError {
                    MessageBanner(message: error, style: .error)
                }

                if model.backupInventory.isEmpty {
                    ContentUnavailableView(
                        "No Backups Loaded",
                        systemImage: "externaldrive",
                        description: Text("Scan a backup directory or a single .psbackup file.")
                    )
                } else {
                    ForEach(model.backupInventory) { item in
                        BackupInventoryRow(item: item)
                    }
                }

                if !model.auditInventory.isEmpty {
                    ForEach(model.auditInventory) { item in
                        AuditInventoryRow(item: item)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1040, alignment: .leading)
        }
    }
}

private struct BackupInventoryRow: View {
    var item: BackupInventoryItem

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(item.path)
                    .font(.headline)
                    .textSelection(.enabled)
                HStack {
                    Label("\(item.fileSize) bytes", systemImage: "doc")
                    if let modifiedAt = item.modifiedAt {
                        Label(modifiedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                    }
                }
                .foregroundStyle(.secondary)
                if let envelope = item.envelope {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        GridRow {
                            Text("Format").foregroundStyle(.secondary)
                            Text(envelope.format)
                        }
                        GridRow {
                            Text("KDF").foregroundStyle(.secondary)
                            Text(envelope.kdf)
                        }
                        GridRow {
                            Text("Iterations").foregroundStyle(.secondary)
                            Text("\(envelope.iterations)")
                        }
                    }
                    .font(.subheadline)
                } else {
                    Label(item.error ?? "Could not inspect backup.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AuditInventoryRow: View {
    var item: AuditInventoryItem

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(item.path)
                    .font(.headline)
                    .textSelection(.enabled)
                HStack {
                    Label("\(item.fileSize) bytes", systemImage: "doc")
                    if let modifiedAt = item.modifiedAt {
                        Label(modifiedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                    }
                }
                .foregroundStyle(.secondary)
                if let receipt = item.receipt {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        GridRow {
                            Text("Operation").foregroundStyle(.secondary)
                            Text(receipt.operation.rawValue)
                        }
                        GridRow {
                            Text("Created").foregroundStyle(.secondary)
                            Text(receipt.createdAt.formatted(date: .abbreviated, time: .shortened))
                        }
                        GridRow {
                            Text("Actions").foregroundStyle(.secondary)
                            Text("\(receipt.actionCount)")
                        }
                        GridRow {
                            Text("Mutating").foregroundStyle(.secondary)
                            Text("\(receipt.mutatingActionCount)")
                        }
                        GridRow {
                            Text("SHA-256").foregroundStyle(.secondary)
                            Text(item.sha256 ?? "unknown")
                                .textSelection(.enabled)
                        }
                    }
                    .font(.subheadline)
                } else {
                    Label(item.error ?? "Could not inspect receipt.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ConflictDiffPanel: View {
    var action: SyncAction

    private var diffs: [CredentialFieldDiff] {
        guard let source = action.sourceRecord,
              let destination = action.destinationRecord else {
            return []
        }
        return CredentialDiff.fieldDiffs(source: source, destination: destination)
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(action.key.description)
                            .font(.headline)
                        Text(action.reason)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(action.kind.rawValue)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Field").font(.caption.weight(.semibold))
                        Text("Source").font(.caption.weight(.semibold))
                        Text("Destination").font(.caption.weight(.semibold))
                    }
                    Divider()
                        .gridCellColumns(3)
                    ForEach(diffs) { diff in
                        GridRow {
                            Text(diff.field.rawValue)
                                .foregroundStyle(.secondary)
                            Text(diff.sourceValue.isEmpty ? "<empty>" : diff.sourceValue)
                            Text(diff.destinationValue.isEmpty ? "<empty>" : diff.destinationValue)
                        }
                    }
                }
                .font(.subheadline)
            }
        }
    }
}

private struct LimitationsView: View {
    private let rows = [
        ("Passkeys are not migrated", "Use provider-supported FIDO Credential Exchange or manual reenrollment."),
        ("Apple TOTP writes are blocked", "The Keychain internet-password API does not create Passwords.app verification-code entries."),
        ("Only login records are in scope", "Secure notes, cards, identities, SSH keys, Wi-Fi passwords, and custom item types are not synced."),
        ("Continuous sync is not available", "This app performs one-time plan/apply workflows."),
        ("Restore is limited", "Restore handles backed-up website/app login records one provider at a time and still blocks passkey/TOTP unsafe cases."),
        ("Apple behavior depends on local state", "Keychain permissions and iCloud Keychain settings affect live provider behavior.")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HeaderView(title: "Limitations", subtitle: "Known boundaries that the app keeps visible before live sync.")
                ForEach(rows, id: \.0) { row in
                    GroupBox(row.0) {
                        Text(row.1)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
        }
    }
}

private struct PlanResultsView: View {
    var plan: SyncPlan?
    var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let message {
                MessageBanner(message: message, style: .info)
            }

            if let plan {
                PlanSummary(plan: plan)
                Divider()
                List(plan.actions, id: \.key) { action in
                    ActionRow(action: action)
                }
                .listStyle(.inset)
            } else {
                ContentUnavailableView(
                    "No Plan Yet",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Run a dry plan to inspect the actions PassSync would take.")
                )
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct PlanSummary: View {
    var plan: SyncPlan

    var body: some View {
        HStack(spacing: 12) {
            MetricView(title: "Actions", value: "\(plan.actions.count)")
            MetricView(title: "Creates", value: "\(count(.createInOnePassword) + count(.createInApple))")
            MetricView(title: "Updates", value: "\(count(.updateOnePassword) + count(.updateApple))")
            MetricView(title: "Blocked", value: "\(count(.conflict) + count(.unsupported))")
        }
    }

    private func count(_ kind: SyncActionKind) -> Int {
        plan.actions.filter { $0.kind == kind }.count
    }
}

private struct ActionRow: View {
    var action: SyncAction

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(action.key.description)
                    .font(.headline)
                Text(action.kind.rawValue)
                    .font(.caption)
                    .foregroundStyle(color)
                Text(action.reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let source = action.sourceRecord, let destination = action.destinationRecord {
                    let diffs = CredentialDiff.fieldDiffs(source: source, destination: destination)
                    if !diffs.isEmpty {
                        Text("\(diffs.count) field difference\(diffs.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var icon: String {
        switch action.kind {
        case .createInOnePassword, .createInApple:
            return "plus.circle"
        case .updateOnePassword, .updateApple:
            return "arrow.triangle.2.circlepath.circle"
        case .skipIdentical:
            return "checkmark.circle"
        case .conflict:
            return "questionmark.circle"
        case .unsupported:
            return "exclamationmark.triangle"
        }
    }

    private var color: Color {
        switch action.kind {
        case .createInOnePassword, .createInApple:
            return .blue
        case .updateOnePassword, .updateApple:
            return .orange
        case .skipIdentical:
            return .green
        case .conflict:
            return .purple
        case .unsupported:
            return .red
        }
    }
}

private struct HeaderView: View {
    var title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.largeTitle.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
        }
    }
}

private struct FormPanel<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        GroupBox(title) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                content
            }
            .textFieldStyle(.roundedBorder)
            .padding(.top, 4)
        }
        .padding(20)
    }
}

private struct PrimaryButton: View {
    var title: String
    var systemImage: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.borderedProminent)
    }
}

private struct StatusRow: View {
    var title: String
    var value: String
    var isGood: Bool

    var body: some View {
        HStack {
            Label(title, systemImage: isGood ? "checkmark.circle" : "xmark.octagon")
                .foregroundStyle(isGood ? .green : .red)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}

private struct MetricView: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.title2.weight(.semibold))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(minWidth: 110, alignment: .leading)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct MessageBanner: View {
    enum Style {
        case info
        case error
    }

    var message: String
    var style: Style

    var body: some View {
        Label(message, systemImage: style == .info ? "info.circle" : "xmark.octagon")
            .foregroundStyle(foregroundColor)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(backgroundColor.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var foregroundColor: Color {
        style == .info ? .secondary : .red
    }

    private var backgroundColor: Color {
        style == .info ? .blue : .red
    }
}

#Preview {
    ContentView()
        .environmentObject(AppModel())
}
