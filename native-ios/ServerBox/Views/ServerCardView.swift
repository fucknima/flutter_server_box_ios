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
                            Label("Open terminal", systemImage: "terminal")
                        }
                        Button {
                            onOpenSFTP()
                        } label: {
                            Label("Open SFTP", systemImage: "folder")
                        }
                        Button {
                            onOpenProcesses()
                        } label: {
                            Label("Processes", systemImage: "cpu")
                        }
                        Button {
                            onOpenTools()
                        } label: {
                            Label("Server tools", systemImage: "wrench.and.screwdriver")
                        }
                        Button {
                            onDisconnect()
                        } label: {
                            Label("Disconnect", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    default:
                        Button {
                            onConnect()
                        } label: {
                            Label("Connect", systemImage: "rectangle.portrait.and.arrow.right")
                        }

                        if canTrustHost {
                            Button {
                                onTrustAndConnect()
                            } label: {
                                Label(
                                    server.knownHostKey == nil ? "Trust and connect" : "Replace host key",
                                    systemImage: "checkmark.shield"
                                )
                            }
                        }
                    }

                    if server.statusURL != nil {
                        Button {
                            onRefresh()
                        } label: {
                            Label("Refresh monitor", systemImage: "arrow.clockwise")
                        }
                    }

                    Button {
                        onEdit()
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    Divider()
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Actions for \(displayName)")
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
                Label("Edit", systemImage: "pencil")
            }
            Button {
                pendingPowerAction = .suspend
            } label: {
                Label("Suspend", systemImage: "pause.circle")
            }
            Button(role: .destructive) {
                pendingPowerAction = .shutdown
            } label: {
                Label("Shutdown", systemImage: "power")
            }
            Divider()
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
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
            Button("Cancel", role: .cancel) {
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
        return message.contains("Fingerprint:") && !message.hasPrefix("Jump host ")
    }

    @ViewBuilder
    private var monitorContent: some View {
        switch state {
        case .idle:
            Text(
                server.statusURL == nil
                    ? "Connect over SSH to load server status."
                    : "Ready to refresh the HTTP monitor."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        case .loading:
            HStack(spacing: DesignTokens.spaceS) {
                ProgressView()
                Text("Loading monitor status...")
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
                    title: "Memory",
                    value: status.memory,
                    fraction: status.memoryFraction,
                    systemImage: "memorychip"
                )
                StatusMetricRow(
                    title: "Disk",
                    value: status.disk,
                    fraction: status.diskFraction,
                    systemImage: "internaldrive"
                )
                StatusMetricRow(
                    title: "Network",
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
                    Text("Unable to load monitor status")
                        .font(.subheadline.weight(.semibold))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Spacer(minLength: DesignTokens.spaceS)
                Button("Retry", action: onRefresh)
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
            return "SSH disconnected"
        case .connecting:
            return "Connecting over SSH..."
        case .connected:
            return "SSH connected"
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
        case .suspend: "Suspend"
        case .shutdown: "Shutdown"
        }
    }

    var confirmationMessage: String {
        switch self {
        case .suspend: "Suspend this server over SSH?"
        case .shutdown: "Shut down this server over SSH?"
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
