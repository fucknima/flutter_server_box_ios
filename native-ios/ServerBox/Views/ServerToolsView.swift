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
    @Published var containerToRemove: RemoteContainer?
    @Published var inspectedOutput: (title: String, content: String)?
    @Published var isLoadingOutput = false

    private let listServices: () async throws -> [RemoteSystemService]
    private let controlService: (RemoteSystemService, SystemServiceAction) async throws -> Void
    private let serviceStatus: (RemoteSystemService) async throws -> String
    private let listContainers: () async throws -> [RemoteContainer]
    private let controlContainer: (RemoteContainer, ContainerAction) async throws -> Void
    private let removeContainer: (RemoteContainer, Bool) async throws -> Void
    private let onOpenTerminal: (String) -> Void

    init(
        listServices: @escaping () async throws -> [RemoteSystemService],
        controlService: @escaping (RemoteSystemService, SystemServiceAction) async throws -> Void,
        serviceStatus: @escaping (RemoteSystemService) async throws -> String,
        listContainers: @escaping () async throws -> [RemoteContainer],
        controlContainer: @escaping (RemoteContainer, ContainerAction) async throws -> Void,
        removeContainer: @escaping (RemoteContainer, Bool) async throws -> Void,
        onOpenTerminal: @escaping (String) -> Void
    ) {
        self.listServices = listServices
        self.controlService = controlService
        self.serviceStatus = serviceStatus
        self.listContainers = listContainers
        self.controlContainer = controlContainer
        self.removeContainer = removeContainer
        self.onOpenTerminal = onOpenTerminal
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

    func inspectService(_ service: RemoteSystemService) async {
        isLoadingOutput = true
        defer { isLoadingOutput = false }
        do {
            let content = try await serviceStatus(service)
            inspectedOutput = (title: service.unit, content: content)
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

    func confirmRemoveContainer(force: Bool) async {
        guard let container = containerToRemove else { return }
        do {
            try await removeContainer(container, force)
            containerToRemove = nil
            await loadContainers()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openContainerLogs(_ container: RemoteContainer) {
        onOpenTerminal(
            "\(container.runtime) logs -f --tail 100 '\(container.identifier)'"
        )
    }
}

struct ServerToolsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: ServerToolsViewModel

    init(
        listServices: @escaping () async throws -> [RemoteSystemService],
        controlService: @escaping (RemoteSystemService, SystemServiceAction) async throws -> Void,
        serviceStatus: @escaping (RemoteSystemService) async throws -> String,
        listContainers: @escaping () async throws -> [RemoteContainer],
        controlContainer: @escaping (RemoteContainer, ContainerAction) async throws -> Void,
        removeContainer: @escaping (RemoteContainer, Bool) async throws -> Void,
        onOpenTerminal: @escaping (String) -> Void
    ) {
        _viewModel = StateObject(
            wrappedValue: ServerToolsViewModel(
                listServices: listServices,
                controlService: controlService,
                serviceStatus: serviceStatus,
                listContainers: listContainers,
                controlContainer: controlContainer,
                removeContainer: removeContainer,
                onOpenTerminal: onOpenTerminal
            )
        )
    }

    var body: some View {
        NavigationStack {
            TabView {
                ServicesTab(viewModel: viewModel)
                    .tabItem { Label("服务", systemImage: "gearshape.2") }
                ContainersTab(viewModel: viewModel)
                    .tabItem { Label("容器", systemImage: "shippingbox") }
            }
            .navigationTitle("服务器工具")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task {
                await viewModel.loadAll()
            }
            .alert(
                "工具错误",
                isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { isPresented in
                        if !isPresented { viewModel.errorMessage = nil }
                    }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "未知工具错误")
            }
            .sheet(item: Binding(
                get: {
                    viewModel.inspectedOutput.map {
                        OutputItem(title: $0.title, content: $0.content)
                    }
                },
                set: { if $0 == nil { viewModel.inspectedOutput = nil } }
            )) { item in
                OutputSheet(title: item.title, content: item.content)
            }
        }
        .tint(DesignTokens.accent)
    }
}

private struct OutputItem: Identifiable {
    let title: String
    let content: String
    var id: String { title }
}

private struct OutputSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let content: String

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(content)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
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
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("状态") {
                    Task { await viewModel.inspectService(service) }
                }
                .disabled(viewModel.isLoadingOutput)
            }
        }
        .overlay { emptyState(title: "暂无 systemd 服务", loading: viewModel.isLoadingServices) }
        .refreshable { await viewModel.loadServices() }
        .confirmationDialog(
            "控制系统服务？",
            isPresented: Binding(
                get: { viewModel.serviceToControl != nil },
                set: { isPresented in
                    if !isPresented { viewModel.serviceToControl = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("启动") { Task { await viewModel.applyServiceAction(.start) } }
            Button("停止", role: .destructive) { Task { await viewModel.applyServiceAction(.stop) } }
            Button("重启") { Task { await viewModel.applyServiceAction(.restart) } }
            Button("查看状态") {
                let service = viewModel.serviceToControl
                viewModel.serviceToControl = nil
                if let service {
                    Task { await viewModel.inspectService(service) }
                }
            }
            Button("取消", role: .cancel) {}
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
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("删除", role: .destructive) {
                    viewModel.containerToRemove = container
                }
                Button("日志") {
                    viewModel.openContainerLogs(container)
                }
            }
        }
        .overlay { emptyState(title: "暂无容器", loading: viewModel.isLoadingContainers) }
        .refreshable { await viewModel.loadContainers() }
        .confirmationDialog(
            "控制容器？",
            isPresented: Binding(
                get: { viewModel.containerToControl != nil },
                set: { isPresented in
                    if !isPresented { viewModel.containerToControl = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("启动") { Task { await viewModel.applyContainerAction(.start) } }
            Button("停止", role: .destructive) { Task { await viewModel.applyContainerAction(.stop) } }
            Button("重启") { Task { await viewModel.applyContainerAction(.restart) } }
            Button("查看日志") {
                let container = viewModel.containerToControl
                viewModel.containerToControl = nil
                if let container {
                    viewModel.openContainerLogs(container)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(viewModel.containerToControl?.name ?? "")
        }
        .alert(
            "删除容器？",
            isPresented: Binding(
                get: { viewModel.containerToRemove != nil },
                set: { isPresented in
                    if !isPresented { viewModel.containerToRemove = nil }
                }
            )
        ) {
            Button("删除") {
                Task { await viewModel.confirmRemoveContainer(force: false) }
            }
            Button("强制删除", role: .destructive) {
                Task { await viewModel.confirmRemoveContainer(force: true) }
            }
            Button("取消", role: .cancel) {
                viewModel.containerToRemove = nil
            }
        } message: {
            Text("删除容器 \(viewModel.containerToRemove?.name ?? "")？运行中的容器请先停止，或使用强制删除（rm -f）。")
        }
    }
}

@ViewBuilder
private func emptyState(title: LocalizedStringKey, loading: Bool) -> some View {
    if loading {
        ProgressView("正在加载...")
    } else {
        ContentUnavailableView(title, systemImage: "server.rack")
    }
}
