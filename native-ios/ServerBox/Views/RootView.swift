import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var viewModel: ServerListViewModel
    @State private var editorRoute: EditorRoute?
    @State private var serverToDelete: ServerConfiguration?
    @State private var serverToTrust: ServerConfiguration?
    @State private var terminalServer: ServerConfiguration?
    @State private var sftpServer: ServerConfiguration?

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
                TerminalView {
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
                    }
                )
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
                Button("Trust and connect") {
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
                Text("This explicitly skips host-key verification for this connection. Prefer saving a trusted host key before connecting when possible.")
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
                        terminalServer = server
                    },
                    onOpenSFTP: {
                        sftpServer = server
                    },
                    onEdit: {
                        editorRoute = .edit(server)
                    },
                    onDelete: {
                        serverToDelete = server
                    }
                )
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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
            ServerEditorView { draft in
                try await viewModel.save(draft)
            }
        case .edit(let server):
            ServerEditorView(server: server) { draft in
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
