import SwiftUI

struct ConnectionStatsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: ConnectionStatsViewModel
    @State private var selectedServer: ServerConnectionStats?
    @State private var isShowingClearConfirmation = false
    @State private var isShowingCompactConfirmation = false
    @State private var compactBeforeSize: Int64 = 0
    @State private var compactResultMessage: String?

    @MainActor
    init(viewModel: ConnectionStatsViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("连接统计")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .task {
                    await viewModel.load()
                }
                .refreshable {
                    await viewModel.load()
                }
                .sheet(item: $selectedServer) { stats in
                    ConnectionStatsDetailView(stats: stats) { serverID in
                        Task { await viewModel.clear(serverID: serverID) }
                    }
                }
                .confirmationDialog(
                    "删除全部连接历史？",
                    isPresented: $isShowingClearConfirmation
                ) {
                    Button("全部删除", role: .destructive) {
                        Task { await viewModel.clearAll() }
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("这会删除所有服务器的连接记录。")
                }
                .confirmationDialog(
                    "清理旧连接记录？",
                    isPresented: $isShowingCompactConfirmation
                ) {
                    Button("清理", role: .destructive) {
                        Task {
                            if let result = await viewModel.compact() {
                                compactResultMessage =
                                    "压缩前 \(byteString(result.beforeBytes)) → 压缩后 \(byteString(result.afterBytes))"
                            }
                        }
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("当前数据库大小：\(byteString(compactBeforeSize))。将删除 30 天前的记录。")
                }
                .alert(
                    "清理完成",
                    isPresented: Binding(
                        get: { compactResultMessage != nil },
                        set: { if !$0 { compactResultMessage = nil } }
                    )
                ) {
                    Button("好", role: .cancel) {}
                } message: {
                    Text(compactResultMessage ?? "")
                }
                .alert(
                    "连接统计错误",
                    isPresented: Binding(
                        get: { viewModel.errorMessage != nil },
                        set: { isPresented in
                            if !isPresented { viewModel.errorMessage = nil }
                        }
                    )
                ) {
                    Button("好", role: .cancel) {}
                } message: {
                    Text(viewModel.errorMessage ?? "未知错误")
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.serverStats.isEmpty {
            ProgressView("正在加载连接统计...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.serverStats.isEmpty {
            ContentUnavailableView(
                "暂无连接统计",
                systemImage: "chart.bar.xaxis",
                description: Text("SSH 连接尝试记录会显示在这里。")
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
                    Text("服务器")
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("完成") {
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
            .accessibilityLabel("刷新连接统计")

            Button {
                Task {
                    compactBeforeSize = await viewModel.databaseSize()
                    isShowingCompactConfirmation = true
                }
            } label: {
                if viewModel.isCompacting {
                    ProgressView()
                } else {
                    Image(systemName: "archivebox")
                }
            }
            .disabled(viewModel.isCompacting)
            .accessibilityLabel("清理旧连接记录")

            Button(role: .destructive) {
                isShowingClearConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .disabled(viewModel.serverStats.isEmpty)
            .accessibilityLabel("删除全部连接统计")
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: bytes,
            countStyle: .file
        )
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
                    Text("\(stats.totalAttempts) \(String(localized: "次连接尝试"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: DesignTokens.spaceS)

                Text(successRateText)
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .foregroundStyle(successRateColor)
            }

            HStack(spacing: DesignTokens.spaceL) {
                StatCount(label: "成功", value: stats.successCount, color: .green)
                StatCount(label: "失败", value: stats.failureCount, color: .red)
                if let lastConnection = stats.recentConnections.first {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("最近尝试")
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
                    TimelineLabel(title: "最近成功", date: lastSuccessTime, color: .green)
                    TimelineLabel(title: "最近失败", date: lastFailureTime, color: .red)
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
    @Environment(\.dismiss) private var dismiss
    let stats: ServerConnectionStats
    let onClear: (UUID) -> Void
    @State private var isShowingClearConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                Section("概要") {
                    LabeledContent("成功率", value: "\(Int((stats.successRate * 100).rounded()))%")
                    LabeledContent("尝试次数", value: "\(stats.totalAttempts)")
                    LabeledContent("成功次数", value: "\(stats.successCount)")
                    LabeledContent("失败次数", value: "\(stats.failureCount)")
                }

                Section("最近连接") {
                    ForEach(stats.recentConnections) { stat in
                        ConnectionStatRow(stat: stat, showsError: true)
                    }
                }

                Section {
                    Button("清除此服务器统计", role: .destructive) {
                        isShowingClearConfirmation = true
                    }
                }
            }
            .navigationTitle(stats.serverName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .confirmationDialog(
                "清除此服务器的连接统计？",
                isPresented: $isShowingClearConfirmation
            ) {
                Button("清除统计", role: .destructive) {
                    onClear(stats.serverID)
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这会删除「\(stats.serverName)」的全部连接记录，且无法恢复。")
            }
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
                    Text(LocalizedStringKey(stat.result.displayName))
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
