import SwiftUI

struct ServerDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let server: ServerConfiguration
    let state: ServerStatusState
    let connectionState: SSHConnectionState
    let onRefresh: () -> Void
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onOpenTerminal: () -> Void
    let onOpenSFTP: () -> Void
    let onOpenProcesses: () -> Void
    let onOpenTools: () -> Void
    let onOpenPVE: () -> Void
    let onOpenIperf: () -> Void
    let onOpenPortForward: () -> Void
    let onEdit: () -> Void
    @State private var inspectingCustomCommand: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignTokens.spaceM) {
                    summaryHeader
                    actionBar
                    configurationSection
                    statusSection
                    customCommandsSection
                }
                .padding(DesignTokens.spaceM)
            }
            .navigationTitle(server.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("编辑", action: onEdit)
                }
            }
        }
        .tint(DesignTokens.accent)
    }

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spaceS) {
            HStack(alignment: .firstTextBaseline) {
                if let logoURL = resolvedLogoURL {
                    AsyncImage(url: logoURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFit()
                                .frame(width: 40, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        default:
                            Image(systemName: "server.rack")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                                .frame(width: 40, height: 40)
                        }
                    }
                }
                Text(server.name)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                Spacer()
                Image(systemName: connectionIcon)
                    .foregroundStyle(connectionColor)
                    .imageScale(.large)
            }
            Text("\(server.username)@\(server.host):\(server.port)")
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.secondary)
            if !server.tags.isEmpty {
                Text(server.tags.map { "#\($0)" }.joined(separator: "  "))
                    .font(.caption)
                    .foregroundStyle(DesignTokens.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.spaceM)
        .background(DesignTokens.surface)
        .clipShape(.rect(cornerRadius: DesignTokens.radiusM))
    }

    private var actionBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DesignTokens.spaceS) {
                primaryAction
                secondaryActions
            }
            VStack(alignment: .leading, spacing: DesignTokens.spaceS) {
                primaryAction
                secondaryActions
            }
        }
    }

    private var primaryAction: some View {
        Group {
            switch connectionState {
            case .connected:
                Button("断开连接", action: onDisconnect)
                    .buttonStyle(.bordered)
            case .connecting:
                ProgressView("连接中...")
            case .disconnected, .failed:
                Button("连接", action: onConnect)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var secondaryActions: some View {
        HStack(spacing: DesignTokens.spaceS) {
            Button("终端", action: onOpenTerminal)
                .disabled(connectionState != .connected)
            Button("SFTP", action: onOpenSFTP)
                .disabled(connectionState != .connected)
            Button("刷新", action: onRefresh)
        }
        .buttonStyle(.bordered)
    }

    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spaceS) {
            Text("配置")
                .font(.headline)
            LabeledContent("主机", value: server.host)
            LabeledContent("端口", value: "\(server.port)")
            LabeledContent("用户名", value: server.username)
            LabeledContent("认证方式") {
                Text(authenticationTitle)
            }
            if let statusURL = server.statusURL {
                LabeledContent("状态监控", value: statusURL.absoluteString)
            }
            if !server.normalizedJumpServerIDs.isEmpty {
                LabeledContent("跳板主机", value: "\(server.normalizedJumpServerIDs.count)")
            }
            if let proxyCommand = server.proxyCommand, !proxyCommand.isEmpty {
                LabeledContent("代理命令", value: proxyCommand)
            }
            LabeledContent("Proxmox 工具", value: server.pveEnabled ? "已启用" : "已禁用")
        }
        .padding(DesignTokens.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.surface)
        .clipShape(.rect(cornerRadius: DesignTokens.radiusM))
    }

    @ViewBuilder
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spaceS) {
            Text("实时状态")
                .font(.headline)
            switch state {
            case .idle:
                ContentUnavailableView(
                    "暂无状态",
                    systemImage: "chart.bar",
                    description: Text("刷新监控或通过 SSH 连接以加载状态。")
                )
                .frame(maxWidth: .infinity)
            case .loading:
                ProgressView("正在加载状态...")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, DesignTokens.spaceL)
            case .failed(let message):
                Label {
                    Text(message)
                        .font(.subheadline)
                } icon: {
                    Image(systemName: "wifi.exclamationmark")
                        .foregroundStyle(.red)
                }
            case .loaded(let status):
                statusMetrics(status)
            }
        }
        .padding(DesignTokens.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.surface)
        .clipShape(.rect(cornerRadius: DesignTokens.radiusM))

        if connectionState == .connected {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignTokens.spaceS) {
                    detailToolButtons
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DesignTokens.spaceS) {
                        detailToolButtons
                    }
                }
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var detailToolButtons: some View {
        Button("进程", action: onOpenProcesses)
        Button("服务器工具", action: onOpenTools)
        if server.pveEnabled {
            Button("PVE", action: onOpenPVE)
        }
        Button("iperf", action: onOpenIperf)
        Button("端口转发", action: onOpenPortForward)
    }

    @ViewBuilder
    private var customCommandsSection: some View {
        if case .loaded(let status) = state, !status.customCmds.isEmpty {
            let entries = status.customCmds.sorted { $0.key < $1.key }
            VStack(alignment: .leading, spacing: DesignTokens.spaceS) {
                Text("自定义命令")
                    .font(.headline)
                ForEach(entries, id: \.key) { key, value in
                    Button {
                        inspectingCustomCommand = key
                    } label: {
                        HStack(spacing: DesignTokens.spaceS) {
                            Text(key)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(oneLine(value))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.trailing)
                            if value.contains("\n") {
                                Image(systemName: "info.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(DesignTokens.spaceM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.surface)
            .clipShape(.rect(cornerRadius: DesignTokens.radiusM))
            .sheet(
                isPresented: Binding(
                    get: { inspectingCustomCommand != nil },
                    set: { if !$0 { inspectingCustomCommand = nil } }
                )
            ) {
                customCommandOutputSheet(inspectingCustomCommand ?? "")
            }
        }
    }

    private func customCommandOutputSheet(_ key: String) -> some View {
        let value: String = {
            if case .loaded(let status) = state {
                return status.customCmds[key] ?? ""
            }
            return ""
        }()
        return NavigationStack {
            ScrollView {
                Text(value)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
            }
            .navigationTitle(key)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { inspectingCustomCommand = nil }
                }
            }
        }
        .tint(DesignTokens.accent)
    }

    private func oneLine(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var resolvedLogoURL: URL? {
        guard let logoURL = server.logoURL else { return nil }
        var urlString = logoURL.absoluteString
        if case .loaded(let status) = state, !status.dist.isEmpty {
            urlString = urlString.replacingOccurrences(of: "{DIST}", with: status.dist)
        }
        urlString = urlString.replacingOccurrences(
            of: "{BRIGHT}",
            with: colorScheme == .dark ? "dark" : "light"
        )
        return URL(string: urlString)
    }

    private func statusMetrics(_ status: ServerStatus) -> some View {
        VStack(spacing: DesignTokens.spaceM) {
            DetailMetricRow(title: "CPU", value: status.cpu, fraction: status.cpuFraction, image: "cpu")
            if !status.cpuCores.isEmpty {
                ForEach(Array(status.cpuCores.enumerated()), id: \.offset) { index, value in
                    DetailMetricRow(
                        title: "核心 \(index + 1)",
                        value: String(format: "%.1f%%", value),
                        fraction: min(max(value / 100, 0), 1),
                        image: "cpu"
                    )
                }
            }
            DetailMetricRow(title: "内存", value: status.memory, fraction: status.memoryFraction, image: "memorychip")
            if !status.swap.isEmpty {
                DetailMetricRow(title: "交换", value: status.swap, fraction: status.swapFraction, image: "memorychip")
            }
            if !status.disks.isEmpty {
                ForEach(Array(status.disks.enumerated()), id: \.offset) { index, disk in
                    DetailMetricRow(
                        title: disk.name,
                        value: "\(LinuxStatusParser.humanBytes(disk.used)) / \(LinuxStatusParser.humanBytes(disk.total))",
                        fraction: min(max(disk.usedPercent / 100, 0), 1),
                        image: "internaldrive"
                    )
                }
            }
            DetailMetricRow(title: "网络", value: status.network, fraction: nil, image: "network")
            if !status.temps.isEmpty {
                ForEach(status.temps.sorted(by: { $0.key < $1.key }), id: \.key) { name, value in
                    DetailMetricRow(
                        title: name,
                        value: String(format: "%.1f°C", value),
                        fraction: nil,
                        image: "thermometer"
                    )
                }
            }
            if !status.uptime.isEmpty {
                DetailMetricRow(title: "运行时间", value: status.uptime, fraction: nil, image: "clock")
            }
        }
    }

    private var authenticationTitle: LocalizedStringKey {
        switch server.authentication {
        case .password: "密码"
        case .privateKey: "私钥"
        }
    }

    private var connectionIcon: String {
        switch connectionState {
        case .connected: "checkmark.circle.fill"
        case .connecting: "arrow.triangle.2.circlepath"
        case .disconnected: "circle"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    private var connectionColor: Color {
        switch connectionState {
        case .connected: .green
        case .connecting: .orange
        case .disconnected: .secondary
        case .failed: .red
        }
    }
}

private struct DetailMetricRow: View {
    let title: LocalizedStringKey
    let value: String
    let fraction: Double?
    let image: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(title, systemImage: image)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value.isEmpty ? "-" : value)
                    .font(.system(.subheadline, design: .monospaced, weight: .medium))
            }
            if let fraction {
                ProgressView(value: fraction)
                    .tint(DesignTokens.statusColor(for: fraction))
            }
        }
    }
}
