import SwiftUI

struct ServerCardView: View {
    @Environment(\.colorScheme) private var colorScheme
    let server: ServerConfiguration
    let state: ServerStatusState
    let connectionState: SSHConnectionState
    let onOpenDetail: () -> Void
    let onRefresh: () -> Void
    let onConnect: () -> Void
    let onTrustAndConnect: () -> Void
    let onDisconnect: () -> Void
    let onOpenTerminal: () -> Void
    let onOpenSFTP: () -> Void
    let onOpenProcesses: () -> Void
    let onOpenTools: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onSuspend: () -> Void
    let onShutdown: () -> Void

    @State private var pendingPowerAction: PowerAction?

    enum PowerAction: String, Identifiable {
        case suspend
        case shutdown

        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spaceM) {
            HStack(alignment: .top, spacing: DesignTokens.spaceS) {
                logoView

                VStack(alignment: .leading, spacing: 4) {
                    Button(action: onOpenDetail) {
                        Text(displayName)
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    Text("\(server.username)@\(server.host):\(server.port)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: DesignTokens.spaceS)

                if let topRightText {
                    Text(topRightText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }

                Menu {
                    switch connectionState {
                    case .connected:
                        Button {
                            onOpenTerminal()
                        } label: {
                            Label("打开终端", systemImage: "terminal")
                        }
                        Button {
                            onOpenSFTP()
                        } label: {
                            Label("打开 SFTP", systemImage: "folder")
                        }
                        Button {
                            onOpenProcesses()
                        } label: {
                            Label("进程", systemImage: "cpu")
                        }
                        Button {
                            onOpenTools()
                        } label: {
                            Label("服务器工具", systemImage: "wrench.and.screwdriver")
                        }
                        Button {
                            onDisconnect()
                        } label: {
                            Label("断开连接", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    default:
                        Button {
                            onConnect()
                        } label: {
                            Label("连接", systemImage: "rectangle.portrait.and.arrow.right")
                        }

                        if canTrustHost {
                            Button {
                                onTrustAndConnect()
                            } label: {
                                Label(
                                    server.knownHostKey == nil ? "信任并连接" : "替换主机密钥",
                                    systemImage: "checkmark.shield"
                                )
                            }
                        }
                    }

                    if server.statusURL != nil {
                        Button {
                            onRefresh()
                        } label: {
                            Label("刷新监控", systemImage: "arrow.clockwise")
                        }
                    }

                    Button {
                        onEdit()
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }
                    Divider()
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("\(displayName) 的操作")
            }

            connectionSummary
            monitorContent
        }
        .padding(DesignTokens.spaceM)
        .background(DesignTokens.surface)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.radiusM)
                .strokeBorder(.primary.opacity(0.06))
        }
        .contextMenu {
            Button {
                onEdit()
            } label: {
                Label("编辑", systemImage: "pencil")
            }
            Button {
                pendingPowerAction = .suspend
            } label: {
                Label("挂起", systemImage: "pause.circle")
            }
            Button(role: .destructive) {
                pendingPowerAction = .shutdown
            } label: {
                Label("关机", systemImage: "power")
            }
            Divider()
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .confirmationDialog(
            pendingPowerAction?.confirmationTitle ?? "",
            isPresented: Binding(
                get: { pendingPowerAction != nil },
                set: { if !$0 { pendingPowerAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(pendingPowerAction?.confirmationTitle ?? "", role: .destructive) {
                switch pendingPowerAction {
                case .suspend: onSuspend()
                case .shutdown: onShutdown()
                case nil: break
                }
                pendingPowerAction = nil
            }
            Button("取消", role: .cancel) {
                pendingPowerAction = nil
            }
        } message: {
            Text(pendingPowerAction?.confirmationMessage ?? "")
        }
    }

    @ViewBuilder
    private var logoView: some View {
        if let logoURL = resolvedLogoURL {
            AsyncImage(url: logoURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                default:
                    Image(systemName: "server.rack")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                }
            }
        }
    }

    private var topRightText: String? {
        guard case .loaded(let status) = state else { return nil }
        guard let value = status.customCmds["server_card_top_right"] else { return nil }
        let lines = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n")
        guard let last = lines.last?.trimmingCharacters(in: .whitespacesAndNewlines),
              !last.isEmpty else { return nil }
        return last
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

    private var connectionSummary: some View {
        HStack(spacing: DesignTokens.spaceS) {
            Image(systemName: connectionIcon)
                .foregroundStyle(connectionColor)
            Text(connectionTitle)
                .font(.subheadline.weight(.medium))
            Spacer()
            if case .connecting = connectionState {
                ProgressView()
            }
        }
    }

    private var canTrustHost: Bool {
        guard case .failed(let message) = connectionState else { return false }
        let isFingerprint = message.contains("Fingerprint:") || message.contains("指纹：")
        let isJumpHost = message.hasPrefix("Jump host ") || message.hasPrefix("跳板")
        return isFingerprint && !isJumpHost
    }

    @ViewBuilder
    private var monitorContent: some View {
        switch state {
        case .idle:
            Text(
                server.statusURL == nil
                    ? "通过 SSH 连接以加载服务器状态。"
                    : "可以刷新 HTTP 监控。"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        case .loading:
            HStack(spacing: DesignTokens.spaceS) {
                ProgressView()
                Text("正在加载监控状态...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        case .loaded(let status):
            VStack(spacing: DesignTokens.spaceS) {
                StatusMetricRow(
                    title: "CPU",
                    value: status.cpu,
                    fraction: status.cpuFraction,
                    systemImage: "cpu"
                )
                StatusMetricRow(
                    title: "内存",
                    value: status.memory,
                    fraction: status.memoryFraction,
                    systemImage: "memorychip"
                )
                StatusMetricRow(
                    title: "磁盘",
                    value: status.disk,
                    fraction: status.diskFraction,
                    systemImage: "internaldrive"
                )
                StatusMetricRow(
                    title: "网络",
                    value: status.network,
                    fraction: nil,
                    systemImage: "network"
                )
            }
        case .failed(let message):
            HStack(alignment: .top, spacing: DesignTokens.spaceS) {
                Image(systemName: "wifi.exclamationmark")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 4) {
                    Text("无法加载监控状态")
                        .font(.subheadline.weight(.semibold))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Spacer(minLength: DesignTokens.spaceS)
                Button("重试", action: onRefresh)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var displayName: String {
        if case .loaded(let status) = state, !status.name.isEmpty {
            return status.name
        }
        return server.name
    }

    private var connectionTitle: String {
        switch connectionState {
        case .disconnected:
            return "SSH 未连接"
        case .connecting:
            return "正在通过 SSH 连接..."
        case .connected:
            return "SSH 已连接"
        case .failed(let message):
            return message
        }
    }

    private var connectionIcon: String {
        switch connectionState {
        case .disconnected:
            return "circle"
        case .connecting:
            return "arrow.triangle.2.circlepath"
        case .connected:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.circle.fill"
        }
    }

    private var connectionColor: Color {
        switch connectionState {
        case .disconnected:
            return .secondary
        case .connecting:
            return .orange
        case .connected:
            return .green
        case .failed:
            return .red
        }
    }
}

private extension ServerCardView.PowerAction {
    var confirmationTitle: String {
        switch self {
        case .suspend: "挂起"
        case .shutdown: "关机"
        }
    }

    var confirmationMessage: String {
        switch self {
        case .suspend: "通过 SSH 挂起此服务器？"
        case .shutdown: "通过 SSH 关闭此服务器？"
        }
    }
}

private struct StatusMetricRow: View {
    let title: String
    let value: String
    let fraction: Double?
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: DesignTokens.spaceS) {
                Label(title, systemImage: systemImage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value.isEmpty ? "-" : value)
                    .font(.system(.subheadline, design: .monospaced, weight: .medium))
                    .lineLimit(1)
            }

            if let fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(DesignTokens.statusColor(for: fraction))
            }
        }
    }
}
