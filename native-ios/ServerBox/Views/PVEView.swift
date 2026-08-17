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
                    ProgressView("Loading PVE resources...")
                } else if !viewModel.isLoading && viewModel.resources.isEmpty {
                    ContentUnavailableView(
                        "No PVE resources",
                        systemImage: "server.rack",
                        description: Text("The server did not return Proxmox resources.")
                    )
                }
            }
            .navigationTitle("PVE")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
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
                    .accessibilityLabel("Refresh PVE resources")
                }
            }
            .task { await viewModel.load() }
            .confirmationDialog(
                "Control PVE resource?",
                isPresented: Binding(
                    get: { viewModel.resourceToControl != nil },
                    set: { if !$0 { viewModel.resourceToControl = nil } }
                )
            ) {
                Button("Start") { Task { await viewModel.apply(.start) } }
                Button("Stop", role: .destructive) { Task { await viewModel.apply(.stop) } }
                Button("Reboot") { Task { await viewModel.apply(.reboot) } }
                Button("Shutdown", role: .destructive) { Task { await viewModel.apply(.shutdown) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(viewModel.resourceToControl?.displayName ?? "")
            }
            .alert(
                "PVE error",
                isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { if !$0 { viewModel.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "Unknown PVE error")
            }
        }
        .tint(DesignTokens.accent)
    }

    private var resourceGroups: [PVEGroup] {
        let order = ["node", "qemu", "lxc", "storage", "sdn"]
        let grouped = Dictionary(grouping: viewModel.resources, by: { $0.type })
        let known = order.compactMap { type in
            guard let resources = grouped[type], !resources.isEmpty else { return nil }
            return PVEGroup(
                title: type.uppercased(),
                resources: resources.sorted {
                    $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                }
            )
        }
        let extra = grouped.keys
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
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: resource.isRunning ? "play.circle.fill" : "stop.circle")
                    .foregroundStyle(resource.isRunning ? .green : .secondary)
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
            if let cpu = resource.cpu {
                ProgressView(value: resource.maxCPU.map { $0 > 0 ? min(1, cpu / $0) : 0 } ?? 0)
                    .tint(DesignTokens.accent)
            }
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
        .padding(.vertical, 3)
    }

    private func byteString(_ value: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(min(value, UInt64(Int64.max))),
            countStyle: .file
        )
    }
}
