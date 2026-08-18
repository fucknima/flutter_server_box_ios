import SwiftUI

struct PortForwardView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: PortForwardViewModel
    private let serverID: UUID
    let serverName: String
    @State private var editingConfiguration: PortForwardConfiguration?
    @State private var showingEditor = false
    @State private var configurationToDelete: PortForwardConfiguration?

    init(server: ServerConfiguration) {
        serverID = server.id
        serverName = server.name
        _viewModel = StateObject(
            wrappedValue: PortForwardViewModel(serverID: server.id)
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.configurations.isEmpty {
                    ContentUnavailableView(
                        "暂无端口转发规则",
                        systemImage: "arrow.left.arrow.right",
                        description: Text("添加端口转发规则以开始使用。")
                    )
                } else {
                    List {
                        ForEach(viewModel.configurations) { configuration in
                            ruleRow(configuration)
                        }
                    }
                }
            }
            .navigationTitle("端口转发")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editingConfiguration = nil
                        showingEditor = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("添加端口转发规则")
                }
            }
            .task {
                await viewModel.load()
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                    } catch {
                        return
                    }
                    await viewModel.refreshStatuses()
                }
            }
            .refreshable {
                await viewModel.load()
            }
            .sheet(isPresented: $showingEditor) {
                PortForwardEditorView(
                    serverID: serverID,
                    serverName: serverName,
                    configuration: editingConfiguration
                ) { configuration in
                    if editingConfiguration == nil {
                        return await viewModel.add(configuration)
                    } else {
                        return await viewModel.update(configuration)
                    }
                }
            }
            .confirmationDialog(
                "删除端口转发规则？",
                isPresented: Binding(
                    get: { configurationToDelete != nil },
                    set: { isPresented in
                        if !isPresented { configurationToDelete = nil }
                    }
                )
            ) {
                Button("删除", role: .destructive) {
                    guard let configurationToDelete else { return }
                    Task { await viewModel.remove(configurationToDelete) }
                    self.configurationToDelete = nil
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(configurationToDelete?.name ?? "")
            }
            .alert(
                "端口转发错误",
                isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { isPresented in
                        if !isPresented { viewModel.errorMessage = nil }
                    }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "未知端口转发错误")
            }
        }
        .tint(DesignTokens.accent)
    }

    private func ruleRow(_ configuration: PortForwardConfiguration) -> some View {
        let status = viewModel.statuses[configuration.id] ?? .inactive
        return HStack(spacing: DesignTokens.spaceS) {
            Image(systemName: statusIcon(for: status))
                .foregroundStyle(statusColor(for: status))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(configuration.name)
                    .font(.headline)
                Text(configuration.displayAddress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .failed(let message) = status {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: DesignTokens.spaceS)
            Toggle(
                "",
                isOn: Binding(
                    get: { status.isActive },
                    set: { _ in
                        Task { await viewModel.toggle(configuration) }
                    }
                )
            )
            .labelsHidden()
            .disabled(status == .starting)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("编辑", systemImage: "pencil") {
                editingConfiguration = configuration
                showingEditor = true
            }
            Button("删除", systemImage: "trash", role: .destructive) {
                configurationToDelete = configuration
            }
        }
    }

    private func statusIcon(for status: PortForwardStatus) -> String {
        switch status {
        case .inactive: "link.badge.plus"
        case .starting: "arrow.triangle.2.circlepath"
        case .active: "link"
        case .failed: "exclamationmark.link"
        }
    }

    private func statusColor(for status: PortForwardStatus) -> Color {
        switch status {
        case .inactive: .secondary
        case .starting: .orange
        case .active: .green
        case .failed: .red
        }
    }
}

private struct PortForwardEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let serverID: UUID
    let serverName: String
    let existingConfiguration: PortForwardConfiguration?
    let onSave: (PortForwardConfiguration) async -> Bool
    @State private var name: String
    @State private var type: PortForwardType
    @State private var localHost: String
    @State private var localPort: String
    @State private var remoteHost: String
    @State private var remotePort: String
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(
        serverID: UUID,
        serverName: String,
        configuration: PortForwardConfiguration?,
        onSave: @escaping (PortForwardConfiguration) async -> Bool
    ) {
        self.serverID = serverID
        self.serverName = serverName
        existingConfiguration = configuration
        self.onSave = onSave
        _name = State(initialValue: configuration?.name ?? "")
        _type = State(initialValue: configuration?.type ?? .local)
        _localHost = State(initialValue: configuration?.localHost ?? "localhost")
        _localPort = State(initialValue: configuration.map { String($0.localPort) } ?? "")
        _remoteHost = State(initialValue: configuration?.remoteHost ?? "")
        _remotePort = State(initialValue: configuration?.remotePort.map(String.init) ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称", text: $name)
                    Picker("类型", selection: $type) {
                        Text("本地").tag(PortForwardType.local)
                        Text("远程").tag(PortForwardType.remote)
                        Text("SOCKS5").tag(PortForwardType.dynamic)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text(existingConfiguration == nil ? "添加规则" : "编辑规则")
                } footer: {
                    Text(serverName)
                }

                Section("本地端点") {
                    TextField("绑定主机", text: $localHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("端口", text: $localPort)
                        .keyboardType(.numberPad)
                }

                if type != .dynamic {
                    Section("远程端点") {
                        TextField("主机", text: $remoteHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("端口", text: $remotePort)
                            .keyboardType(.numberPad)
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("端口转发")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(isSaving)
                }
            }
            .overlay {
                if isSaving {
                    ProgressView()
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .tint(DesignTokens.accent)
    }

    private func save() {
        guard !isSaving else { return }
        guard let localPort = Int(localPort.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = PortForwardConfigurationError.invalidLocalPort.errorDescription
            return
        }
        let parsedRemotePort = Int(remotePort.trimmingCharacters(in: .whitespacesAndNewlines))
        guard type == .dynamic || parsedRemotePort != nil else {
            errorMessage = PortForwardConfigurationError.invalidRemoteEndpoint.errorDescription
            return
        }

        let configuration = PortForwardConfiguration(
            id: existingConfiguration?.id ?? UUID(),
            serverID: existingConfiguration?.serverID ?? serverID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            type: type,
            localHost: localHost.trimmingCharacters(in: .whitespacesAndNewlines),
            localPort: localPort,
            remoteHost: type == .dynamic ? nil : remoteHost.trimmingCharacters(in: .whitespacesAndNewlines),
            remotePort: type == .dynamic ? nil : parsedRemotePort
        )

        do {
            try configuration.validate()
            isSaving = true
            Task {
                if await onSave(configuration) {
                    dismiss()
                }
                isSaving = false
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
