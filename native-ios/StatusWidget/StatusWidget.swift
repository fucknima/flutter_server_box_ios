import AppIntents
import SwiftUI
import WidgetKit

struct StatusWidgetEntry: TimelineEntry {
    let date: Date
    let url: String?
    let status: WidgetStatusData?
    let error: String?
}

struct StatusWidgetConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Status URL"
    static let description = IntentDescription(
        "The /status endpoint URL of a ServerBox Monitor server."
    )

    @Parameter(title: "URL")
    var url: String
}

struct StatusWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> StatusWidgetEntry {
        StatusWidgetEntry(date: Date(), url: nil, status: nil, error: nil)
    }

    func snapshot(
        for configuration: StatusWidgetConfigurationIntent,
        in context: Context
    ) async -> StatusWidgetEntry {
        await entry(for: configuration)
    }

    func timeline(
        for configuration: StatusWidgetConfigurationIntent,
        in context: Context
    ) async -> Timeline<StatusWidgetEntry> {
        let entry = await entry(for: configuration)
        let nextRefresh = Calendar.current.date(
            byAdding: .minute,
            value: 30,
            to: Date()
        ) ?? Date().addingTimeInterval(1800)
        return Timeline(entries: [entry], policy: .after(nextRefresh))
    }

    private func entry(
        for configuration: StatusWidgetConfigurationIntent
    ) async -> StatusWidgetEntry {
        guard let url = StatusURLValidator.validate(configuration.url) else {
            return StatusWidgetEntry(
                date: Date(),
                url: configuration.url,
                status: nil,
                error: "URL must end with /status (https, or http for LAN IPs)."
            )
        }
        do {
            let status = try await WidgetStatusFetcher.fetch(url: url)
            return StatusWidgetEntry(
                date: Date(),
                url: url.absoluteString,
                status: status,
                error: nil
            )
        } catch {
            return StatusWidgetEntry(
                date: Date(),
                url: url.absoluteString,
                status: nil,
                error: error.localizedDescription
            )
        }
    }
}

struct StatusWidget: Widget {
    let kind = "StatusWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: StatusWidgetConfigurationIntent.self,
            provider: StatusWidgetProvider()
        ) { entry in
            StatusWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(.systemBackground)
                }
        }
        .configurationDisplayName("ServerBox Status")
        .description("Show the live status of a ServerBox Monitor server.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryRectangular,
            .accessoryInline,
        ])
    }
}

struct StatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StatusWidgetEntry

    var body: some View {
        if family == .accessoryRectangular || family == .accessoryInline {
            accessoryView
        } else {
            systemView
        }
    }

    private var accessoryView: some View {
        Group {
            if let status = entry.status {
                if family == .accessoryInline {
                    Text("\(displayName): CPU \(status.cpu)")
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName)
                            .font(.headline)
                        Text("CPU \(status.cpu)")
                        Text("Mem \(status.memory)")
                    }
                }
            } else {
                Text(entry.error ?? "Configure the status URL.")
            }
        }
    }

    private var systemView: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let status = entry.status {
                HStack {
                    Text(displayName)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "server.rack")
                        .foregroundStyle(.secondary)
                }
                MetricLine(title: "CPU", value: status.cpu, image: "cpu")
                MetricLine(title: "Memory", value: status.memory, image: "memorychip")
                MetricLine(title: "Disk", value: status.disk, image: "internaldrive")
                MetricLine(title: "Network", value: status.network, image: "network")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ServerBox")
                        .font(.headline)
                    Text(entry.error ?? "Configure the status URL.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var displayName: String {
        if let status = entry.status, !status.name.isEmpty {
            return status.name
        }
        return "ServerBox"
    }
}

private struct MetricLine: View {
    let title: String
    let value: String
    let image: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: image)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value.isEmpty ? "-" : value)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
        }
    }
}
