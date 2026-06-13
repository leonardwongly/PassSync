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
                }
            }

            if let error = model.liveError {
                MessageBanner(message: error, style: .error)
            }

            PlanResultsView(plan: model.livePlan, message: model.liveMessage)
        }
    }

    private var canApply: Bool {
        guard let plan = model.livePlan else { return false }
        return !model.isRunningLivePlan &&
            !model.isApplyingLivePlan &&
            !model.backupPassphrase.isEmpty &&
            plan.actions.allSatisfy { $0.kind != .conflict && $0.kind != .unsupported }
    }
}

private struct LimitationsView: View {
    private let rows = [
        ("Passkeys are not migrated", "Use provider-supported FIDO Credential Exchange or manual reenrollment."),
        ("Apple TOTP writes are blocked", "The Keychain internet-password API does not create Passwords.app verification-code entries."),
        ("Only login records are in scope", "Secure notes, cards, identities, SSH keys, Wi-Fi passwords, and custom item types are not synced."),
        ("Continuous sync is not available", "This app performs one-time plan/apply workflows."),
        ("Restore is not implemented", "Backups can be created and validated by the CLI; restore is future work."),
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
