import SwiftUI

struct ServerDetailView: View {
    @Environment(\.dismiss) private var dismiss
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
    let onEdit: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignTokens.spaceM) {
                    summaryHeader
                    actionBar
                    configurationSection
                    statusSection
                }
                .padding(DesignTokens.spaceM)
            }
            .navigationTitle(server.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit", action: onEdit)
                }
            }
        }
        .tint(DesignTokens.accent)
    }

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spaceS) {
            HStack(alignment: .firstTextBaseline) {
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
                Button("Disconnect", action: onDisconnect)
                    .buttonStyle(.bordered)
            case .connecting:
                ProgressView("Connecting...")
            case .disconnected, .failed:
                Button("Connect", action: onConnect)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var secondaryActions: some View {
        HStack(spacing: DesignTokens.spaceS) {
            Button("Terminal", action: onOpenTerminal)
                .disabled(connectionState != .connected)
            Button("SFTP", action: onOpenSFTP)
                .disabled(connectionState != .connected)
            Button("Refresh", action: onRefresh)
        }
        .buttonStyle(.bordered)
    }

    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spaceS) {
            Text("Configuration")
                .font(.headline)
            LabeledContent("Host", value: server.host)
            LabeledContent("Port", value: "\(server.port)")
            LabeledContent("Username", value: server.username)
            LabeledContent("Authentication", value: authenticationTitle)
            if let statusURL = server.statusURL {
                LabeledContent("Status monitor", value: statusURL.absoluteString)
            }
            if !server.normalizedJumpServerIDs.isEmpty {
                LabeledContent("Jump hosts", value: "\(server.normalizedJumpServerIDs.count)")
            }
            if let proxyCommand = server.proxyCommand, !proxyCommand.isEmpty {
                LabeledContent("Proxy command", value: proxyCommand)
            }
        }
        .padding(DesignTokens.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.surface)
        .clipShape(.rect(cornerRadius: DesignTokens.radiusM))
    }

    @ViewBuilder
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spaceS) {
            Text("Live status")
                .font(.headline)
            switch state {
            case .idle:
                ContentUnavailableView(
                    "No status yet",
                    systemImage: "chart.bar",
                    description: Text("Refresh the monitor or connect over SSH to load status.")
                )
                .frame(maxWidth: .infinity)
            case .loading:
                ProgressView("Loading status...")
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
            HStack(spacing: DesignTokens.spaceS) {
                Button("Processes", action: onOpenProcesses)
                Button("Server tools", action: onOpenTools)
            }
            .buttonStyle(.bordered)
        }
    }

    private func statusMetrics(_ status: ServerStatus) -> some View {
        VStack(spacing: DesignTokens.spaceM) {
            DetailMetricRow(title: "CPU", value: status.cpu, fraction: status.cpuFraction, image: "cpu")
            DetailMetricRow(title: "Memory", value: status.memory, fraction: status.memoryFraction, image: "memorychip")
            DetailMetricRow(title: "Disk", value: status.disk, fraction: status.diskFraction, image: "internaldrive")
            DetailMetricRow(title: "Network", value: status.network, fraction: nil, image: "network")
        }
    }

    private var authenticationTitle: LocalizedStringKey {
        switch server.authentication {
        case .password: "Password"
        case .privateKey: "Private key"
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
