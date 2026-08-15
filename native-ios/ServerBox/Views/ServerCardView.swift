import SwiftUI

struct ServerCardView: View {
    let server: MonitorServer
    let state: ServerStatusState
    let onRefresh: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spaceM) {
            HStack(alignment: .top, spacing: DesignTokens.spaceS) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName)
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .lineLimit(1)
                    Text(server.statusURL.absoluteString)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: DesignTokens.spaceS)

                Menu {
                    Button {
                        onRefresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
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

            content
        }
        .padding(DesignTokens.spaceM)
        .background(DesignTokens.surface)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.radiusM)
                .strokeBorder(.primary.opacity(0.06))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            Text("Ready to refresh")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .loading:
            HStack(spacing: DesignTokens.spaceS) {
                ProgressView()
                Text("Loading status...")
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
                    Text("Unable to load status")
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
