import SwiftUI

private struct PVEGroup: Identifiable {
    let title: String
    let resources: [PVEResource]

    var id: String { title }
}

@MainActor
final class PVEViewModel: ObservableObject {
    @Published private(set) var resources: [PVEResource] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var resourceToControl: PVEResource?

    private let listResources: () async throws -> [PVEResource]
    private let controlResource: (PVEResource, PVEAction) async throws -> Void

    init(
        listResources: @escaping () async throws -> [PVEResource],
        controlResource: @escaping (PVEResource, PVEAction) async throws -> Void
    ) {
        self.listResources = listResources
        self.controlResource = controlResource
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            resources = try await listResources()
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func apply(_ action: PVEAction) async {
        guard let resource = resourceToControl else { return }
        do {
            try await controlResource(resource, action)
            resourceToControl = nil
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct PVEView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: PVEViewModel

    init(
        listResources: @escaping () async throws -> [PVEResource],
        controlResource: @escaping (PVEResource, PVEAction) async throws -> Void
    ) {
        _viewModel = StateObject(
            wrappedValue: PVEViewModel(
                listResources: listResources,
                controlResource: controlResource
            )
        )
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(resourceGroups) { group in
                    Section(group.title) {
                        ForEach(group.resources) { resource in
                            if resource.type == "qemu" || resource.type == "lxc" {
                                Button {
                                    viewModel.resourceToControl = resource
                                } label: {
                                    resourceRow(resource)
                                }
                                .buttonStyle(.plain)
                            } else {
                                resourceRow(resource)
                            }
                        }
                    }
                }
            }
            .overlay {
                if viewModel.isLoading && viewModel.resources.isEmpty {
                    ProgressView("正在加载 PVE 资源...")
                } else if !viewModel.isLoading && viewModel.resources.isEmpty {
                    ContentUnavailableView(
                        "暂无 PVE 资源",
                        systemImage: "server.rack",
                        description: Text("服务器没有返回 Proxmox 资源。")
                    )
                }
            }
            .navigationTitle("PVE")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await viewModel.load() }
                    } label: {
                        if viewModel.isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(viewModel.isLoading)
                    .accessibilityLabel("刷新 PVE 资源")
                }
            }
            .task {
                await autoRefresh()
            }
            .confirmationDialog(
                "控制 PVE 资源？",
                isPresented: Binding(
                    get: { viewModel.resourceToControl != nil },
                    set: { if !$0 { viewModel.resourceToControl = nil } }
                )
            ) {
                Button("启动") { Task { await viewModel.apply(.start) } }
                Button("停止", role: .destructive) { Task { await viewModel.apply(.stop) } }
                Button("重启") { Task { await viewModel.apply(.reboot) } }
                Button("关机", role: .destructive) { Task { await viewModel.apply(.shutdown) } }
                Button("取消", role: .cancel) {}
            } message: {
                Text(viewModel.resourceToControl?.displayName ?? "")
            }
            .alert(
                "PVE 错误",
                isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { if !$0 { viewModel.errorMessage = nil } }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "未知 PVE 错误")
            }
        }
        .tint(DesignTokens.accent)
    }

    private var resourceGroups: [PVEGroup] {
        let order = ["node", "qemu", "lxc", "storage", "sdn"]
        let grouped = Dictionary(grouping: viewModel.resources, by: { $0.type })
        let known: [PVEGroup] = order.compactMap { type in
            guard let resources = grouped[type], !resources.isEmpty else { return nil }
            return PVEGroup(
                title: type.uppercased(),
                resources: resources.sorted {
                    $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                }
            )
        }
        let extra: [PVEGroup] = grouped.keys
            .filter { !order.contains($0) }
            .sorted()
            .compactMap { type in
                guard let resources = grouped[type], !resources.isEmpty else { return nil }
                return PVEGroup(
                    title: type.uppercased(),
                    resources: resources.sorted {
                        $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                    }
                )
            }
        return known + extra
    }

    private func resourceRow(_ resource: PVEResource) -> some View {
        switch resource.type {
        case "node":
            return AnyView(nodeRow(resource))
        case "qemu", "lxc":
            return AnyView(vmRow(resource))
        case "storage":
            return AnyView(storageRow(resource))
        default:
            return AnyView(genericRow(resource))
        }
    }

    private func nodeRow(_ resource: PVEResource) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "server.rack")
                    .foregroundStyle(resource.isOnline ? .green : .secondary)
                Text(resource.displayName)
                    .font(.headline)
                Spacer()
                Text(resource.status ?? "unknown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let uptime = resource.uptime {
                Text("运行 \(uptimeText(uptime))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let cpu = resource.cpu {
                usageBar(
                    label: "CPU",
                    percentText: percentText(cpu, max: resource.maxCPU),
                    fraction: resource.maxCPU.map { $0 > 0 ? min(1, cpu / $0) : 0 }
                )
            }
            if let memory = resource.memoryBytes {
                usageBar(
                    label: "内存",
                    percentText: "\(byteString(memory)) / \(byteString(resource.maxMemoryBytes ?? 0))",
                    fraction: resource.memoryFraction
                )
            }
        }
        .padding(.vertical, 3)
    }

    private func vmRow(_ resource: PVEResource) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: resource.isRunning ? "play.circle.fill" : "stop.circle")
                    .foregroundStyle(resource.isRunning ? .green : .secondary)
                Text(resource.displayName)
                    .font(.headline)
                Spacer()
                if let uptime = resource.uptime {
                    Text("运行 \(uptimeText(uptime))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(resource.status ?? "unknown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text("\(resource.node)\(resource.vmid.map { " · \($0)" } ?? "")")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if resource.isRunning {
                HStack(alignment: .top, spacing: DesignTokens.spaceL) {
                    percentCircle(
                        title: "CPU",
                        fraction: cpuFraction(of: resource)
                    )
                    percentCircle(
                        title: "内存",
                        fraction: resource.memoryFraction ?? 0
                    )
                    if resource.diskReadBytes != nil || resource.diskWriteBytes != nil {
                        VStack(alignment: .leading, spacing: 4) {
                            if let read = resource.diskReadBytes {
                                Label("读 \(byteString(read))", systemImage: "arrow.down.circle")
                            }
                            if let write = resource.diskWriteBytes {
                                Label("写 \(byteString(write))", systemImage: "arrow.up.circle")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    if resource.networkInBytes != nil || resource.networkOutBytes != nil {
                        VStack(alignment: .leading, spacing: 4) {
                            if let netIn = resource.networkInBytes {
                                Label("↓ \(byteString(netIn))", systemImage: "arrow.down.to.line")
                            }
                            if let netOut = resource.networkOutBytes {
                                Label("↑ \(byteString(netOut))", systemImage: "arrow.up.to.line")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack(spacing: DesignTokens.spaceM) {
                    if let memory = resource.memoryBytes {
                        Label(byteString(memory), systemImage: "memorychip")
                    }
                    if let disk = resource.diskBytes {
                        Label(byteString(disk), systemImage: "internaldrive")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private func storageRow(_ resource: PVEResource) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "externaldrive")
                    .foregroundStyle(resource.isOnline ? .green : .secondary)
                Text(resource.displayName)
                    .font(.headline)
                Spacer()
                Text(resource.status ?? "unknown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let disk = resource.diskBytes {
                Text("已用 \(byteString(disk)) / 总计 \(byteString(resource.maxDiskBytes ?? 0))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let content = resource.content {
                LabeledContent("内容", value: content)
                    .font(.caption)
            }
            if let pluginType = resource.pluginType {
                LabeledContent("插件类型", value: pluginType)
                    .font(.caption)
            }
        }
        .padding(.vertical, 3)
    }

    private func genericRow(_ resource: PVEResource) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: resource.isRunning ? "play.circle.fill" : "stop.circle")
                    .foregroundStyle(resource.isOnline ? .green : .secondary)
                Text(resource.displayName)
                    .font(.headline)
                Spacer()
                Text(resource.status ?? "unknown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("\(resource.node)\(resource.vmid.map { " · \($0)" } ?? "")")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    private func usageBar(label: String, percentText: String, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(percentText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: fraction ?? 0)
                .tint(DesignTokens.accent)
        }
    }

    private func percentCircle(title: String, fraction: Double) -> some View {
        VStack(spacing: 4) {
            ProgressView(value: fraction)
                .progressViewStyle(.circular)
                .tint(DesignTokens.accent)
                .frame(width: 40, height: 40)
                .overlay {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.caption2.monospacedDigit())
                }
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func cpuFraction(of resource: PVEResource) -> Double {
        guard let cpu = resource.cpu, let maxCPU = resource.maxCPU, maxCPU > 0 else { return 0 }
        return min(1, cpu / maxCPU)
    }

    private func uptimeText(_ seconds: Int) -> String {
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)天\(hours)小时" }
        if hours > 0 { return "\(hours)小时\(minutes)分" }
        return "\(max(minutes, 1))分"
    }

    private func percentText(_ cpu: Double, max maxCPU: Double?) -> String {
        guard let maxCPU, maxCPU > 0 else { return "—" }
        return "\(Int(((cpu / maxCPU) * 100).rounded()))%"
    }

    private func byteString(_ value: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(min(value, UInt64(Int64.max))),
            countStyle: .file
        )
    }

    private func autoRefresh() async {
        while !Task.isCancelled {
            await viewModel.load()
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {
                return
            }
        }
    }
}
