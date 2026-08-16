import SwiftUI

@MainActor
final class ServerToolsViewModel: ObservableObject {
    @Published private(set) var services: [RemoteSystemService] = []
    @Published private(set) var containers: [RemoteContainer] = []
    @Published private(set) var isLoadingServices = false
    @Published private(set) var isLoadingContainers = false
    @Published var errorMessage: String?
    @Published var serviceToControl: RemoteSystemService?
    @Published var containerToControl: RemoteContainer?

    private let listServices: () async throws -> [RemoteSystemService]
    private let controlService: (RemoteSystemService, SystemServiceAction) async throws -> Void
    private let listContainers: () async throws -> [RemoteContainer]
    private let controlContainer: (RemoteContainer, ContainerAction) async throws -> Void

    init(
        listServices: @escaping () async throws -> [RemoteSystemService],
        controlService: @escaping (RemoteSystemService, SystemServiceAction) async throws -> Void,
        listContainers: @escaping () async throws -> [RemoteContainer],
        controlContainer: @escaping (RemoteContainer, ContainerAction) async throws -> Void
    ) {
        self.listServices = listServices
        self.controlService = controlService
        self.listContainers = listContainers
        self.controlContainer = controlContainer
    }

    func loadAll() async {
        await loadServices()
        await loadContainers()
    }

    func loadServices() async {
        isLoadingServices = true
        defer { isLoadingServices = false }
        do {
            services = try await listServices()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadContainers() async {
        isLoadingContainers = true
        defer { isLoadingContainers = false }
        do {
            containers = try await listContainers()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func applyServiceAction(_ action: SystemServiceAction) async {
        guard let service = serviceToControl else { return }
        do {
            try await controlService(service, action)
            serviceToControl = nil
            await loadServices()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func applyContainerAction(_ action: ContainerAction) async {
        guard let container = containerToControl else { return }
        do {
            try await controlContainer(container, action)
            containerToControl = nil
            await loadContainers()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ServerToolsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: ServerToolsViewModel

    init(
        listServices: @escaping () async throws -> [RemoteSystemService],
        controlService: @escaping (RemoteSystemService, SystemServiceAction) async throws -> Void,
        listContainers: @escaping () async throws -> [RemoteContainer],
        controlContainer: @escaping (RemoteContainer, ContainerAction) async throws -> Void
    ) {
        _viewModel = StateObject(
            wrappedValue: ServerToolsViewModel(
                listServices: listServices,
                controlService: controlService,
                listContainers: listContainers,
                controlContainer: controlContainer
            )
        )
    }

    var body: some View {
        NavigationStack {
            TabView {
                ServicesTab(viewModel: viewModel)
                    .tabItem { Label("Services", systemImage: "gearshape.2") }
                ContainersTab(viewModel: viewModel)
                    .tabItem { Label("Containers", systemImage: "shippingbox") }
            }
            .navigationTitle("Server Tools")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task {
                await viewModel.loadAll()
            }
            .alert(
                "Tool error",
                isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { isPresented in
                        if !isPresented { viewModel.errorMessage = nil }
                    }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "Unknown server tool error")
            }
        }
        .tint(DesignTokens.accent)
    }
}

private struct ServicesTab: View {
    @ObservedObject var viewModel: ServerToolsViewModel

    var body: some View {
        List(viewModel.services) { service in
            Button {
                viewModel.serviceToControl = service
            } label: {
                HStack(spacing: DesignTokens.spaceS) {
                    Image(systemName: service.isActive ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(service.isActive ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(service.unit)
                            .font(.system(.subheadline, design: .monospaced, weight: .medium))
                        Text(service.description.isEmpty ? service.subState : service.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Text(service.activeState)
                        .font(.caption)
                        .foregroundStyle(service.isActive ? .green : .secondary)
                }
            }
            .buttonStyle(.plain)
        }
        .overlay { emptyState(title: "No systemd services", loading: viewModel.isLoadingServices) }
        .refreshable { await viewModel.loadServices() }
        .confirmationDialog(
            "Control system service?",
            isPresented: Binding(
                get: { viewModel.serviceToControl != nil },
                set: { isPresented in
                    if !isPresented { viewModel.serviceToControl = nil }
                }
            )
        ) {
            Button("Start") { Task { await viewModel.applyServiceAction(.start) } }
            Button("Stop", role: .destructive) { Task { await viewModel.applyServiceAction(.stop) } }
            Button("Restart") { Task { await viewModel.applyServiceAction(.restart) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(viewModel.serviceToControl?.unit ?? "")
        }
    }
}

private struct ContainersTab: View {
    @ObservedObject var viewModel: ServerToolsViewModel

    var body: some View {
        List(viewModel.containers) { container in
            Button {
                viewModel.containerToControl = container
            } label: {
                HStack(spacing: DesignTokens.spaceS) {
                    Image(systemName: container.isRunning ? "play.circle.fill" : "stop.circle")
                        .foregroundStyle(container.isRunning ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(container.name)
                            .font(.system(.subheadline, design: .monospaced, weight: .medium))
                        Text(container.image)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(container.status)
                            .font(.caption2)
                            .foregroundStyle(container.isRunning ? .green : .secondary)
                    }
                    Spacer()
                    Text(container.runtime)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
        .overlay { emptyState(title: "No containers", loading: viewModel.isLoadingContainers) }
        .refreshable { await viewModel.loadContainers() }
        .confirmationDialog(
            "Control container?",
            isPresented: Binding(
                get: { viewModel.containerToControl != nil },
                set: { isPresented in
                    if !isPresented { viewModel.containerToControl = nil }
                }
            )
        ) {
            Button("Start") { Task { await viewModel.applyContainerAction(.start) } }
            Button("Stop", role: .destructive) { Task { await viewModel.applyContainerAction(.stop) } }
            Button("Restart") { Task { await viewModel.applyContainerAction(.restart) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(viewModel.containerToControl?.name ?? "")
        }
    }
}

@ViewBuilder
private func emptyState(title: LocalizedStringKey, loading: Bool) -> some View {
    if loading {
        ProgressView("Loading...")
    } else {
        ContentUnavailableView(title, systemImage: "server.rack")
    }
}
