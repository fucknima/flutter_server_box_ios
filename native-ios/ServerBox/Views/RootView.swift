import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var viewModel: ServerListViewModel
    @ObservedObject var transferViewModel: SFTPTransferViewModel
    let onSettings: (() -> Void)?
    let onOpenLocalFile: ((URL) -> Void)?
    @State private var editorRoute: EditorRoute?
    @State private var serverToDelete: ServerConfiguration?
    @State private var serverToTrust: ServerConfiguration?
    @State private var terminalServer: ServerConfiguration?
    @State private var terminalCommand: String?
    @State private var sftpServer: ServerConfiguration?
    @State private var processesServer: ServerConfiguration?
    @State private var toolsServer: ServerConfiguration?
    @State private var pveServer: ServerConfiguration?
    @State private var iperfServer: ServerConfiguration?
    @State private var portForwardServer: ServerConfiguration?
    @State private var pendingDetailRoute: PendingDetailRoute?
    @State private var pendingTerminalAfterIperf: ServerConfiguration?
    @State private var detailServer: ServerConfiguration?
    @State private var showingDiscovery = false
    @State private var showingConnectionStats = false

    init(
        viewModel: ServerListViewModel,
        transferViewModel: SFTPTransferViewModel,
        onSettings: (() -> Void)? = nil,
        onOpenLocalFile: ((URL) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.transferViewModel = transferViewModel
        self.onSettings = onSettings
        self.onOpenLocalFile = onOpenLocalFile
    }

    var body: some View {
        rootView
    }

    private var rootView: some View {
        NavigationStack {
            dashboard
            .navigationTitle("Servers")
            .toolbar { toolbarContent }
            .sheet(item: $editorRoute) { route in editorView(for: route) }
            .sheet(item: $terminalServer) { server in
                TerminalView(initialCommand: terminalCommand) {
                    try await viewModel.openTerminal(for: server)
                }
            }
            .sheet(item: $sftpServer) { server in
                SFTPView(
                    listDirectory: { path in
                        try await viewModel.listDirectory(for: server, path: path)
                    },
                    readFile: { path in
                        try await viewModel.readFile(for: server, path: path)
                    },
                    applyMutation: { mutation in
                        try await viewModel.applySFTPMutation(mutation, on: server)
                    },
                    initialPath: {
                        let fallback = server.username == "root"
                            ? "/root"
                            : "/home/\(server.username)"
                        return try await viewModel.homeDirectory(for: server, fallback: fallback)
                    },
                    transferViewModel: transferViewModel,
                    onDownload: { file in
                        transferViewModel.startDownload(server: server, remoteFile: file)
                    },
                    onUpload: { url, path in
                        transferViewModel.startUpload(
                            server: server,
                            localURL: url,
                            remoteDirectory: path
                        )
                    },
                    onShowLocalFile: { url in
                        sftpServer = nil
                        onOpenLocalFile?(url)
                    }
                )
            }
            .sheet(item: $processesServer) { server in
                ProcessesView(
                    listProcesses: {
                        try await viewModel.listProcesses(for: server)
                    },
                    terminateProcess: { process, signal in
                        try await viewModel.terminateProcess(
                            process,
                            on: server,
                            signal: signal
                        )
                    }
                )
            }
            .sheet(item: $toolsServer) { server in
                ServerToolsView(
                    listServices: {
                        try await viewModel.listSystemServices(for: server)
                    },
                    controlService: { service, action in
                        try await viewModel.controlSystemService(
                            service,
                            on: server,
                            action: action
                        )
                    },
                    listContainers: {
                        try await viewModel.listContainers(for: server)
                    },
                    controlContainer: { container, action in
                        try await viewModel.controlContainer(
                            container,
                            on: server,
                            action: action
                        )
                    }
                )
            }
            .sheet(item: $pveServer) { server in
                PVEView(
                    listResources: {
                        try await viewModel.listPVEResources(for: server)
                    },
                    controlResource: { resource, action in
                        try await viewModel.controlPVEResource(
                            resource,
                            on: server,
                            action: action
                        )
                    }
                )
            }
            .sheet(item: $iperfServer, onDismiss: presentPendingIperf) { server in
                IperfView { command in
                    terminalCommand = command
                    pendingTerminalAfterIperf = server
                    iperfServer = nil
                }
            }
            .sheet(item: $portForwardServer) { server in
                PortForwardView(server: server)
            }
            .sheet(item: $detailServer, onDismiss: presentPendingDetailRoute) { server in
                ServerDetailView(
                    server: server,
                    state: viewModel.state(for: server),
                    connectionState: viewModel.connectionState(for: server),
                    onRefresh: {
                        Task { await viewModel.refreshAll() }
                    },
                    onConnect: {
                        Task { await viewModel.connectAndRefresh(server) }
                    },
                    onDisconnect: {
                        Task { await viewModel.disconnect(server) }
                    },
                     onOpenTerminal: {
                         terminalCommand = nil
                         pendingDetailRoute = .terminal(server)
                         detailServer = nil
                     },
                     onOpenSFTP: {
                         pendingDetailRoute = .sftp(server)
                         detailServer = nil
                     },
                     onOpenProcesses: {
                         pendingDetailRoute = .processes(server)
                         detailServer = nil
                     },
                     onOpenTools: {
                         pendingDetailRoute = .tools(server)
                         detailServer = nil
                     },
                     onOpenPVE: {
                         pendingDetailRoute = .pve(server)
                         detailServer = nil
                     },
                     onOpenIperf: {
                         pendingDetailRoute = .iperf(server)
                         detailServer = nil
                     },
                     onOpenPortForward: {
                         pendingDetailRoute = .portForward(server)
                         detailServer = nil
                     },
                     onEdit: {
                         pendingDetailRoute = .edit(server)
                         detailServer = nil
                     }
                )
            }
            .sheet(isPresented: $showingDiscovery) {
                ServerDiscoveryView(serverViewModel: viewModel)
            }
            .sheet(isPresented: $showingConnectionStats) {
                ConnectionStatsView(viewModel: ConnectionStatsViewModel())
            }
            .confirmationDialog(
                "Delete this server?",
                isPresented: Binding(
                    get: { serverToDelete != nil },
                    set: { isPresented in
                        if !isPresented { serverToDelete = nil }
                    }
                )
                ) {
                Button("Delete", role: .destructive) {
                    if let serverToDelete {
                        viewModel.delete(serverToDelete)
                    }
                    serverToDelete = nil
                }
            } message: {
                Text(serverToDelete?.name ?? "")
            }
            .confirmationDialog(
                "Trust this SSH host?",
                isPresented: Binding(
                    get: { serverToTrust != nil },
                    set: { isPresented in
                        if !isPresented { serverToTrust = nil }
                    }
                )
            ) {
                Button(
                    serverToTrust?.knownHostKey == nil
                        ? "Trust and connect"
                        : "Replace host key"
                ) {
                    if let serverToTrust {
                        Task {
                            await viewModel.connectAndRefresh(
                                serverToTrust,
                                allowUnverifiedHostKey: true
                            )
                        }
                    }
                    serverToTrust = nil
                }
                Button("Cancel", role: .cancel) {
                    serverToTrust = nil
                }
            } message: {
                if let server = serverToTrust,
                   case .failed(let message) = viewModel.connectionState(for: server),
                   message.contains("Fingerprint:") {
                    Text("Verify this fingerprint before continuing:\n\n\(message)")
                } else {
                    Text("Verify the server identity before trusting this host key.")
                }
            }
            .alert(
                "Storage error",
                isPresented: Binding(
                    get: { viewModel.storageError != nil },
                    set: { isPresented in
                        if !isPresented { viewModel.storageError = nil }
                    }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.storageError ?? "Unknown error")
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await viewModel.start()
            }
        }
        .tint(DesignTokens.accent)
    }

    private var dashboard: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DesignTokens.spaceM) {
                dashboardHeader
                serverContent
            }
            .padding(.horizontal, DesignTokens.spaceM)
            .padding(.vertical, DesignTokens.spaceL)
        }
        .background(DesignTokens.background.ignoresSafeArea())
        .refreshable {
            await viewModel.refreshAll()
        }
    }

    @ViewBuilder
    private var serverContent: some View {
        if viewModel.servers.isEmpty {
            EmptyStateView {
                editorRoute = .add
            }
        } else {
            ForEach(viewModel.servers) { server in
                ServerCardView(
                    server: server,
                    state: viewModel.state(for: server),
                    connectionState: viewModel.connectionState(for: server),
                    onOpenDetail: {
                        detailServer = server
                    },
                    onRefresh: {
                        Task { await viewModel.refreshAll() }
                    },
                    onConnect: {
                        Task { await viewModel.connectAndRefresh(server) }
                    },
                    onTrustAndConnect: {
                        serverToTrust = server
                    },
                    onDisconnect: {
                        Task { await viewModel.disconnect(server) }
                    },
                    onOpenTerminal: {
                        terminalCommand = nil
                        terminalServer = server
                    },
                    onOpenSFTP: {
                        sftpServer = server
                    },
                    onOpenProcesses: {
                        processesServer = server
                    },
                    onOpenTools: {
                        toolsServer = server
                    },
                    onEdit: {
                        editorRoute = .edit(server)
                    },
                    onDelete: {
                        serverToDelete = server
                    },
                    onSuspend: {
                        Task {
                            try? await viewModel.suspend(server)
                        }
                    },
                    onShutdown: {
                        Task {
                            try? await viewModel.shutdown(server)
                        }
                    }
                )
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if let onSettings {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showingDiscovery = true
            } label: {
                Image(systemName: "dot.radiowaves.left.and.right")
            }
            .accessibilityLabel("Discover servers")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showingConnectionStats = true
            } label: {
                Image(systemName: "chart.bar.xaxis")
            }
            .accessibilityLabel("Connection statistics")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                editorRoute = .add
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add server")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Task { await viewModel.refreshAll() }
            } label: {
                if viewModel.isRefreshing {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(viewModel.servers.isEmpty || viewModel.isRefreshing)
            .accessibilityLabel("Refresh servers")
        }
    }

    @ViewBuilder
    private func editorView(for route: EditorRoute) -> some View {
        switch route {
        case .add:
            ServerEditorView(availableServers: viewModel.servers) { draft in
                try await viewModel.save(draft)
            }
        case .edit(let server):
            ServerEditorView(server: server, availableServers: viewModel.servers) { draft in
                try await viewModel.save(draft)
            }
        }
    }

    private var dashboardHeader: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spaceS) {
            HStack(alignment: .firstTextBaseline) {
                Text("Live monitor")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                Spacer()
                if viewModel.isLoading {
                    ProgressView()
                }
            }

            Text(
                viewModel.servers.isEmpty
                    ? "Add an SSH server to begin."
                    : "SSH connections and optional monitor endpoints are managed here."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.bottom, DesignTokens.spaceS)
    }

    private func presentPendingDetailRoute() {
        guard let route = pendingDetailRoute else { return }
        pendingDetailRoute = nil
        switch route {
        case .terminal(let server):
            terminalServer = server
        case .sftp(let server):
            sftpServer = server
        case .processes(let server):
            processesServer = server
        case .tools(let server):
            toolsServer = server
        case .pve(let server):
            pveServer = server
        case .iperf(let server):
            iperfServer = server
        case .portForward(let server):
            portForwardServer = server
        case .edit(let server):
            editorRoute = .edit(server)
        }
    }

    private func presentPendingIperf() {
        guard let server = pendingTerminalAfterIperf else { return }
        pendingTerminalAfterIperf = nil
        terminalServer = server
    }
}

private enum PendingDetailRoute: Identifiable {
    case terminal(ServerConfiguration)
    case sftp(ServerConfiguration)
    case processes(ServerConfiguration)
    case tools(ServerConfiguration)
    case pve(ServerConfiguration)
    case iperf(ServerConfiguration)
    case portForward(ServerConfiguration)
    case edit(ServerConfiguration)

    var id: String {
        switch self {
        case .terminal(let server): "terminal-\(server.id)"
        case .sftp(let server): "sftp-\(server.id)"
        case .processes(let server): "processes-\(server.id)"
        case .tools(let server): "tools-\(server.id)"
        case .pve(let server): "pve-\(server.id)"
        case .iperf(let server): "iperf-\(server.id)"
        case .portForward(let server): "port-forward-\(server.id)"
        case .edit(let server): "edit-\(server.id)"
        }
    }
}

private enum EditorRoute: Identifiable {
    case add
    case edit(ServerConfiguration)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let server): return "edit-\(server.id.uuidString)"
        }
    }
}

private struct EmptyStateView: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: DesignTokens.spaceM) {
            Image(systemName: "server.rack")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(DesignTokens.accent)

            VStack(spacing: DesignTokens.spaceS) {
                Text("No servers yet")
                    .font(.headline)
                Text("Connect an SSH server to open the native ServerBox tools.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button("Add server", action: onAdd)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, DesignTokens.spaceL)
        .background(DesignTokens.surface)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM))
    }
}
