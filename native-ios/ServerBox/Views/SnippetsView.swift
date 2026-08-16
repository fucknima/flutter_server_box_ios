import SwiftUI

struct SnippetsView: View {
    @ObservedObject var serverViewModel: ServerListViewModel
    let onSettings: () -> Void
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
                        Picker("Tag", selection: $selectedTag) {
                            Text("All").tag("All")
                            ForEach(viewModel.tags, id: \.self) { tag in
                                Text(tag).tag(tag)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                if viewModel.isLoading && viewModel.snippets.isEmpty {
                    ProgressView("Loading snippets...")
                } else if filteredSnippets.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "No snippets" : "No matching snippets",
                        systemImage: "chevron.left.forwardslash.chevron.right",
                        description: Text("Create reusable commands for your SSH sessions.")
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
                                Label("Run on server", systemImage: "play.fill")
                            }
                            Button(role: .destructive) {
                                Task { await viewModel.delete(snippet) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Snippets")
            .searchable(text: $searchText, prompt: "Search snippets")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onSettings) {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editorRoute = .add
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add snippet")
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
                    onRun: { server in
                        try await serverViewModel.execute(snippet.script, on: server)
                    }
                )
            }
            .alert(
                "Snippet error",
                isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { if !$0 { viewModel.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "Unknown snippet error")
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
                Section("Snippet") {
                    TextField("Name", text: $name)
                    TextField("Note", text: $note, axis: .vertical)
                    TextField("Tags, separated by commas", text: $tags)
                }

                Section("Command") {
                    TextEditor(text: $script)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 140)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if !servers.isEmpty {
                    Section("Auto-run servers") {
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
            .navigationTitle(existingSnippet == nil ? "Add snippet" : "Edit snippet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
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
    let onRun: (ServerConfiguration) async throws -> String
    @State private var selectedServerID: UUID?
    @State private var isRunning = false
    @State private var errorMessage: String?
    @State private var output: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Command") {
                    Text(snippet.script)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                Section("Server") {
                    Picker("Run on", selection: $selectedServerID) {
                        Text("Select a server").tag(UUID?.none)
                        ForEach(servers) { server in
                            Text(server.name).tag(UUID?.some(server.id))
                        }
                    }
                    Button("Run") { run() }
                        .disabled(selectedServerID == nil || isRunning)
                }
                if let output {
                    Section("Output") {
                        Text(output)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Run snippet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .overlay { if isRunning { ProgressView() } }
            .alert(
                "Run error",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Unknown run error")
            }
        }
    }

    private func run() {
        guard let selectedServerID,
              let server = servers.first(where: { $0.id == selectedServerID }) else { return }
        isRunning = true
        Task {
            do {
                output = try await onRun(server)
            } catch {
                errorMessage = error.localizedDescription
            }
            isRunning = false
        }
    }
}
