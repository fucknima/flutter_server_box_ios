import SwiftUI

struct SnippetsView: View {
    @ObservedObject var serverViewModel: ServerListViewModel
    let onSettings: () -> Void
    let onOpenTerminal: (NativeSnippet, ServerConfiguration) -> Void
    @StateObject private var viewModel = SnippetListViewModel()
    @State private var searchText = ""
    @State private var selectedTag = "All"
    @State private var editorRoute: SnippetEditorRoute?
    @State private var snippetToRun: NativeSnippet?

    private var filteredSnippets: [NativeSnippet] {
        viewModel.snippets.filter { snippet in
            let matchesTag = selectedTag == "All" || snippet.tags.contains(selectedTag)
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchesSearch = query.isEmpty
                || snippet.name.localizedCaseInsensitiveContains(query)
                || snippet.script.localizedCaseInsensitiveContains(query)
                || snippet.note.localizedCaseInsensitiveContains(query)
            return matchesTag && matchesSearch
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if !viewModel.tags.isEmpty {
                    Section {
                        Picker("标签", selection: $selectedTag) {
                            Text("全部").tag("All")
                            ForEach(viewModel.tags, id: \.self) { tag in
                                Text(tag).tag(tag)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                if viewModel.isLoading && viewModel.snippets.isEmpty {
                    ProgressView("正在加载片段...")
                } else if filteredSnippets.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "暂无片段" : "没有匹配的片段",
                        systemImage: "chevron.left.forwardslash.chevron.right",
                        description: Text("为你的 SSH 会话创建可复用的命令。")
                    )
                } else {
                    ForEach(filteredSnippets) { snippet in
                        Button {
                            editorRoute = .edit(snippet)
                        } label: {
                            snippetRow(snippet)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                snippetToRun = snippet
                            } label: {
                                Label("在服务器上运行", systemImage: "play.fill")
                            }
                            Button(role: .destructive) {
                                Task { await viewModel.delete(snippet) }
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("片段")
            .searchable(text: $searchText, prompt: "搜索片段")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onSettings) {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("设置")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editorRoute = .add
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("添加片段")
                }
            }
            .refreshable { await viewModel.load() }
            .task { await viewModel.loadIfNeeded() }
            .sheet(item: $editorRoute) { route in
                SnippetEditorView(
                    snippet: route.snippet,
                    servers: serverViewModel.servers,
                    onSave: { snippet in await viewModel.save(snippet) }
                )
            }
            .sheet(item: $snippetToRun) { snippet in
                SnippetRunView(
                    snippet: snippet,
                    servers: serverViewModel.servers,
                    onOpenTerminal: onOpenTerminal
                )
            }
            .alert(
                "片段错误",
                isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { if !$0 { viewModel.errorMessage = nil } }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "未知片段错误")
            }
        }
        .tint(DesignTokens.accent)
    }

    private func snippetRow(_ snippet: NativeSnippet) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(snippet.name)
                    .font(.headline)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            if !snippet.note.isEmpty {
                Text(snippet.note)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(snippet.script)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if !snippet.tags.isEmpty {
                Text(snippet.tags.map { "#\($0)" }.joined(separator: "  "))
                    .font(.caption2)
                    .foregroundStyle(DesignTokens.accent)
            }
        }
        .padding(.vertical, DesignTokens.spaceS)
        .contentShape(Rectangle())
    }
}

private enum SnippetEditorRoute: Identifiable {
    case add
    case edit(NativeSnippet)

    var id: String {
        switch self {
        case .add: "add"
        case .edit(let snippet): "edit-\(snippet.id.uuidString)"
        }
    }

    var snippet: NativeSnippet? {
        if case .edit(let snippet) = self { return snippet }
        return nil
    }
}

private struct SnippetEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let existingSnippet: NativeSnippet?
    let servers: [ServerConfiguration]
    let onSave: (NativeSnippet) async -> Void
    @State private var name: String
    @State private var script: String
    @State private var note: String
    @State private var tags: String
    @State private var selectedServers: Set<UUID>
    @State private var isSaving = false

    init(
        snippet: NativeSnippet?,
        servers: [ServerConfiguration],
        onSave: @escaping (NativeSnippet) async -> Void
    ) {
        self.existingSnippet = snippet
        self.servers = servers
        self.onSave = onSave
        _name = State(initialValue: snippet?.name ?? "")
        _script = State(initialValue: snippet?.script ?? "")
        _note = State(initialValue: snippet?.note ?? "")
        _tags = State(initialValue: snippet?.tags.joined(separator: ", ") ?? "")
        _selectedServers = State(initialValue: Set(snippet?.autoRunOn ?? []))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("片段") {
                    TextField("名称", text: $name)
                    TextField("备注", text: $note, axis: .vertical)
                    TextField("标签，以逗号分隔", text: $tags)
                }

                Section("命令") {
                    TextEditor(text: $script)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 140)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if !servers.isEmpty {
                    Section("自动运行服务器") {
                        ForEach(servers) { server in
                            Toggle(server.name, isOn: Binding(
                                get: { selectedServers.contains(server.id) },
                                set: { enabled in
                                    if enabled {
                                        selectedServers.insert(server.id)
                                    } else {
                                        selectedServers.remove(server.id)
                                    }
                                }
                            ))
                        }
                    }
                }
            }
            .navigationTitle(existingSnippet == nil ? "添加片段" : "编辑片段")
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
                if isSaving { ProgressView().padding().background(.regularMaterial, in: .rect(cornerRadius: 12)) }
            }
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        let snippet = NativeSnippet(
            id: existingSnippet?.id ?? UUID(),
            name: name,
            script: script,
            note: note,
            tags: tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
            autoRunOn: selectedServers.sorted { $0.uuidString < $1.uuidString },
            createdAt: existingSnippet?.createdAt ?? Date(),
            updatedAt: Date()
        )
        Task {
            await onSave(snippet)
            isSaving = false
            dismiss()
        }
    }
}

private struct SnippetRunView: View {
    @Environment(\.dismiss) private var dismiss
    let snippet: NativeSnippet
    let servers: [ServerConfiguration]
    let onOpenTerminal: (NativeSnippet, ServerConfiguration) -> Void
    @State private var selectedServerID: UUID?

    var body: some View {
        NavigationStack {
            Form {
                Section("命令") {
                    Text(snippet.script)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                Section("服务器") {
                    Picker("运行于", selection: $selectedServerID) {
                        Text("选择服务器").tag(UUID?.none)
                        ForEach(servers) { server in
                            Text(server.name).tag(UUID?.some(server.id))
                        }
                    }
                    Button("在终端中运行") { runInTerminal() }
                        .disabled(selectedServerID == nil)
                }
                Section {
                    Text("支持 ${host}、${port}、${user}、${pwd}、${id}、${name} 变量，以及 ${ctrl+x}、${alt+x}、${sleep N}、${enter N} 特殊标记。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("片段将在 SSH 终端中逐段执行。")
                }
            }
            .navigationTitle("运行片段")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func runInTerminal() {
        guard let selectedServerID,
              let server = servers.first(where: { $0.id == selectedServerID }) else { return }
        dismiss()
        onOpenTerminal(snippet, server)
    }
}
