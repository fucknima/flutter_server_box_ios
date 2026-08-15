import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var viewModel: ServerListViewModel
    @State private var editorRoute: EditorRoute?
    @State private var serverToDelete: MonitorServer?

    var body: some View {
        rootView
    }

    private var rootView: some View {
        NavigationStack {
            dashboard
            .navigationTitle("Servers")
            .toolbar { toolbarContent }
            .sheet(item: $editorRoute) { route in editorView(for: route) }
            .confirmationDialog(
                "Delete this server?",
                item: $serverToDelete
            ) { server in
                Button("Delete", role: .destructive) {
                    viewModel.delete(server)
                }
            } message: { server in
                Text(server.name)
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
                    onRefresh: {
                        Task { await viewModel.refreshAll() }
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
            ServerEditorView { server in
                viewModel.upsert(server)
            }
        case .edit(let server):
            ServerEditorView(server: server) { updated in
                viewModel.upsert(updated)
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
                    ? "Add a ServerBoxMonitor endpoint to begin."
                    : "Updates automatically while this screen is active."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.bottom, DesignTokens.spaceS)
    }
}

private enum EditorRoute: Identifiable {
    case add
    case edit(MonitorServer)

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
                Text("Connect a monitor endpoint to see CPU, memory, disk, and network status.")
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
