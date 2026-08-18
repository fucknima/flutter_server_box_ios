import SwiftUI

enum NativeHomeTab: String, CaseIterable, Identifiable, Hashable {
    case servers
    case ssh
    case files
    case snippets
    case agent

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .servers: "服务器"
        case .ssh: "SSH"
        case .files: "文件"
        case .snippets: "代码片段"
        case .agent: "Agent"
        }
    }

    var systemImage: String {
        switch self {
        case .servers: "server.rack"
        case .ssh: "terminal"
        case .files: "folder"
        case .snippets: "chevron.left.forwardslash.chevron.right"
        case .agent: "sparkles"
        }
    }
}

struct AppShellView: View {
    @ObservedObject var serverViewModel: ServerListViewModel
    @StateObject private var transferViewModel: SFTPTransferViewModel
    @AppStorage("native.home.tab") private var selectedTabRaw = NativeHomeTab.servers.rawValue
    @AppStorage("native.appearance") private var appearance = "system"
    @AppStorage("native.tab.ssh.enabled") private var sshTabEnabled = true
    @AppStorage("native.tab.files.enabled") private var filesTabEnabled = true
    @AppStorage("native.tab.snippets.enabled") private var snippetsTabEnabled = true
    @AppStorage("native.tab.agent.enabled") private var agentTabEnabled = true
    @State private var showingSettings = false
    @State private var requestedLocalFile: URL?

    init(serverViewModel: ServerListViewModel) {
        self.serverViewModel = serverViewModel
        _transferViewModel = StateObject(
            wrappedValue: SFTPTransferViewModel(serverViewModel: serverViewModel)
        )
    }

    private var selectedTab: Binding<NativeHomeTab> {
        Binding(
            get: { NativeHomeTab(rawValue: selectedTabRaw) ?? .servers },
            set: { selectedTabRaw = $0.rawValue }
        )
    }

    private var visibleTabs: [NativeHomeTab] {
        NativeHomeTab.allCases.filter { tab in
            switch tab {
            case .servers: true
            case .ssh: sshTabEnabled
            case .files: filesTabEnabled
            case .snippets: snippetsTabEnabled
            case .agent: agentTabEnabled
            }
        }
    }

    var body: some View {
        TabView(selection: selectedTab) {
            ForEach(visibleTabs) { tab in
                tabContent(tab)
                    .tag(tab)
                    .tabItem {
                        Label(tab.title, systemImage: tab.systemImage)
                    }
            }
        }
        .onChange(of: visibleTabs) { _, tabs in
            guard !tabs.contains(selectedTab.wrappedValue) else { return }
            selectedTab.wrappedValue = tabs.first ?? .servers
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(serverViewModel: serverViewModel)
        }
        .preferredColorScheme(
            appearance == "dark" ? .dark : appearance == "light" ? .light : nil
        )
    }

    @ViewBuilder
    private func tabContent(_ tab: NativeHomeTab) -> some View {
        switch tab {
        case .servers:
            RootView(
                viewModel: serverViewModel,
                transferViewModel: transferViewModel,
                onSettings: { showingSettings = true },
                onOpenLocalFile: { url in
                    requestedLocalFile = url
                    selectedTabRaw = NativeHomeTab.files.rawValue
                }
            )
        case .ssh:
            SSHTabView(
                serverViewModel: serverViewModel,
                onSettings: { showingSettings = true }
            )
        case .files:
            LocalFilesView(
                onSettings: { showingSettings = true },
                requestedFileURL: requestedLocalFile,
                onConsumeRequestedFile: { requestedLocalFile = nil }
            )
        case .snippets:
            SnippetsView(
                serverViewModel: serverViewModel,
                onSettings: { showingSettings = true }
            )
        case .agent:
            AgentView(onSettings: { showingSettings = true })
        }
    }
}

struct SSHTabView: View {
    @ObservedObject var serverViewModel: ServerListViewModel
    let onSettings: () -> Void
    @State private var terminalServer: ServerConfiguration?

    var body: some View {
        NavigationStack {
            List {
                Section("活动会话") {
                    let connected = serverViewModel.servers.filter {
                        serverViewModel.connectionState(for: $0) == .connected
                    }

                    if connected.isEmpty {
                        ContentUnavailableView(
                            "暂无活动 SSH 会话",
                            systemImage: "terminal",
                            description: Text("连接服务器以打开 SSH 会话。")
                        )
                    } else {
                        ForEach(connected) { server in
                            SSHServerRow(
                                server: server,
                                state: serverViewModel.connectionState(for: server),
                                onOpen: { terminalServer = server },
                                onDisconnect: {
                                    Task { await serverViewModel.disconnect(server) }
                                }
                            )
                        }
                    }
                }

                Section("服务器") {
                    ForEach(serverViewModel.servers) { server in
                        let connectionState = serverViewModel.connectionState(for: server)
                        if connectionState != .connected {
                            SSHServerRow(
                                server: server,
                                state: connectionState,
                                onOpen: {
                                    Task {
                                        await serverViewModel.connectAndRefresh(server)
                                        if serverViewModel.connectionState(for: server) == .connected {
                                            terminalServer = server
                                        }
                                    }
                                },
                                onDisconnect: nil
                            )
                        }
                    }
                }
            }
            .navigationTitle("SSH")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onSettings) {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("设置")
                }
            }
            .refreshable { await serverViewModel.refreshAll() }
            .task { await serverViewModel.loadIfNeeded() }
            .sheet(item: $terminalServer) { server in
                TerminalView {
                    try await serverViewModel.openTerminal(for: server)
                }
            }
        }
        .tint(DesignTokens.accent)
    }
}

private struct SSHServerRow: View {
    let server: ServerConfiguration
    let state: SSHConnectionState
    let onOpen: () -> Void
    let onDisconnect: (() -> Void)?

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: DesignTokens.spaceS) {
                Image(systemName: stateIcon)
                    .foregroundStyle(stateColor)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(server.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(server.username)@\(server.host):\(server.port)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if case .connecting = state {
                    ProgressView()
                } else if onDisconnect != nil {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                } else {
                    Text(actionTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DesignTokens.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let onDisconnect {
                Button("断开连接", role: .destructive, action: onDisconnect)
            }
        }
    }

    private var actionTitle: LocalizedStringKey {
        switch state {
        case .disconnected, .failed: "连接"
        case .connecting: "连接中"
        case .connected: "打开"
        }
    }

    private var stateIcon: String {
        switch state {
        case .disconnected: "circle"
        case .connecting: "arrow.triangle.2.circlepath"
        case .connected: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    private var stateColor: Color {
        switch state {
        case .disconnected: .secondary
        case .connecting: .orange
        case .connected: .green
        case .failed: .red
        }
    }
}
