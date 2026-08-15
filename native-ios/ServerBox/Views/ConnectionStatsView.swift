import SwiftUI

struct ConnectionStatsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: ConnectionStatsViewModel
    @State private var selectedServer: ServerConnectionStats?
    @State private var isShowingClearConfirmation = false

    @MainActor
    init(viewModel: ConnectionStatsViewModel = ConnectionStatsViewModel()) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Connection stats")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .task {
                    await viewModel.load()
                }
                .refreshable {
                    await viewModel.load()
                }
                .sheet(item: $selectedServer) { stats in
                    ConnectionStatsDetailView(stats: stats)
                }
                .confirmationDialog(
                    "Delete all connection history?",
                    isPresented: $isShowingClearConfirmation
                ) {
                    Button("Delete all", role: .destructive) {
                        Task { await viewModel.clearAll() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This removes connection records for every server.")
                }
                .alert(
                    "Connection stats error",
                    isPresented: Binding(
                        get: { viewModel.errorMessage != nil },
                        set: { isPresented in
                            if !isPresented { viewModel.errorMessage = nil }
                        }
                    )
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(viewModel.errorMessage ?? "Unknown error")
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.serverStats.isEmpty {
            ProgressView("Loading connection stats...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.serverStats.isEmpty {
            ContentUnavailableView(
                "No connection stats",
                systemImage: "chart.bar.xaxis",
                description: Text("SSH connection attempts will appear here.")
            )
        } else {
            List {
                Section {
                    ForEach(viewModel.serverStats) { stats in
                        Button {
                            selectedServer = stats
                        } label: {
                            ConnectionStatsCard(stats: stats)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(
                            EdgeInsets(
                                top: DesignTokens.spaceS,
                                leading: DesignTokens.spaceM,
                                bottom: DesignTokens.spaceS,
                                trailing: DesignTokens.spaceM
                            )
                        )
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    Text("Servers")
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Done") {
                dismiss()
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                Task { await viewModel.load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(viewModel.isLoading)
            .accessibilityLabel("Refresh connection stats")

            Button {
                Task { await viewModel.compact() }
            } label: {
                if viewModel.isCompacting {
                    ProgressView()
                } else {
                    Image(systemName: "archivebox")
                }
            }
            .disabled(viewModel.isCompacting)
            .accessibilityLabel("Remove old connection records")

            Button(role: .destructive) {
                isShowingClearConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .disabled(viewModel.serverStats.isEmpty)
            .accessibilityLabel("Delete all connection stats")
        }
    }
}

private struct ConnectionStatsCard: View {
    let stats: ServerConnectionStats

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spaceM) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(stats.serverName)
                        .font(.headline)
                    Text("\(stats.totalAttempts) connection attempts")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: DesignTokens.spaceS)

                Text(successRateText)
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .foregroundStyle(successRateColor)
            }

            HStack(spacing: DesignTokens.spaceL) {
                StatCount(label: "Success", value: stats.successCount, color: .green)
                StatCount(label: "Failed", value: stats.failureCount, color: .red)
                if let lastConnection = stats.recentConnections.first {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Last attempt")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(lastConnection.timestamp, format: .dateTime.month().day().hour().minute())
                            .font(.caption.monospacedDigit())
                    }
                }
                Spacer(minLength: 0)
            }

            if let lastSuccessTime = stats.lastSuccessTime,
               let lastFailureTime = stats.lastFailureTime {
                HStack(spacing: DesignTokens.spaceS) {
                    TimelineLabel(title: "Last success", date: lastSuccessTime, color: .green)
                    TimelineLabel(title: "Last failure", date: lastFailureTime, color: .red)
                }
            }

            ForEach(stats.recentConnections.prefix(3)) { stat in
                ConnectionStatRow(stat: stat)
            }
        }
        .padding(DesignTokens.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.surface)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.radiusM)
                .strokeBorder(.primary.opacity(0.06))
        }
    }

    private var successRateText: String {
        "\(Int((stats.successRate * 100).rounded()))%"
    }

    private var successRateColor: Color {
        switch stats.successRate {
        case 0.8...:
            return .green
        case 0.5..<0.8:
            return .orange
        default:
            return .red
        }
    }
}

private struct StatCount: View {
    let label: String
    let value: Int
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value, format: .number)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(color)
        }
    }
}

private struct TimelineLabel: View {
    let title: String
    let date: Date
    let color: Color

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(date, format: .dateTime.month().day().hour().minute())
                    .font(.caption2.monospacedDigit())
            }
        } icon: {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(color)
        }
    }
}

private struct ConnectionStatsDetailView: View {
    let stats: ServerConnectionStats

    var body: some View {
        NavigationStack {
            List {
                Section("Summary") {
                    LabeledContent("Success rate", value: "\(Int((stats.successRate * 100).rounded()))%")
                    LabeledContent("Total attempts", value: "\(stats.totalAttempts)")
                    LabeledContent("Successful", value: "\(stats.successCount)")
                    LabeledContent("Failed", value: "\(stats.failureCount)")
                }

                Section("Recent connections") {
                    ForEach(stats.recentConnections) { stat in
                        ConnectionStatRow(stat: stat, showsError: true)
                    }
                }
            }
            .navigationTitle(stats.serverName)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct ConnectionStatRow: View {
    let stat: ConnectionStat
    var showsError = false

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.spaceS) {
            Image(systemName: stat.result.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(stat.result.isSuccess ? .green : .red)
                .imageScale(.medium)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(stat.result.displayName)
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: DesignTokens.spaceS)
                    Text("\(stat.durationMilliseconds) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text(stat.timestamp, format: .dateTime.month().day().hour().minute().second())
                    if showsError, !stat.errorMessage.isEmpty {
                        Text(stat.errorMessage)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}
