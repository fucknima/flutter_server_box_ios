import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var serverViewModel: ServerListViewModel
    @AppStorage("native.appearance") private var appearance = "system"
    @AppStorage("native.tab.ssh.enabled") private var sshTabEnabled = true
    @AppStorage("native.tab.files.enabled") private var filesTabEnabled = true
    @AppStorage("native.tab.snippets.enabled") private var snippetsTabEnabled = true
    @AppStorage("native.tab.agent.enabled") private var agentTabEnabled = true
    @AppStorage("native.agent.baseURL") private var agentBaseURL = "https://api.openai.com/v1/"
    @AppStorage("native.agent.model") private var agentModel = "gpt-4o-mini"
    @State private var agentAPIKey = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                }

                Section("Home tabs") {
                    Toggle("SSH", isOn: $sshTabEnabled)
                    Toggle("Files", isOn: $filesTabEnabled)
                    Toggle("Snippets", isOn: $snippetsTabEnabled)
                    Toggle("Agent", isOn: $agentTabEnabled)
                    Text("Servers is always enabled.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("ServerBox") {
                    NavigationLink("Connection statistics") {
                        ConnectionStatsView(viewModel: ConnectionStatsViewModel())
                    }
                    NavigationLink("Server discovery") {
                        ServerDiscoveryView(serverViewModel: serverViewModel)
                    }
                    NavigationLink("Private keys") {
                        PrivateKeysView()
                    }
                    NavigationLink("Backup") {
                        BackupView(serverViewModel: serverViewModel)
                    }
                }

                Section("iOS push") {
                    pushTokenRow
                } footer: {
                    Text("Use the push token with your own push service. Self-compiled builds cannot use the project push service.")
                }

                Section("SSH terminal") {
                    NavigationLink("Virtual keys") {
                        VirtKeysView()
                    }
                }

                Section("Advanced") {
                    NavigationLink("Edit raw settings") {
                        RawSettingsEditorView()
                    }
                }

                Section {
                    TextField("API endpoint", text: $agentBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("API key", text: $agentAPIKey)
                    TextField("Model", text: $agentModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Agent")
                } footer: {
                    Text("Use an OpenAI-compatible chat completions endpoint. The API key is stored in Keychain.")
                }

                Section("About") {
                    LabeledContent("Native UI", value: "SwiftUI")
                    LabeledContent("Home widget", value: "WidgetKit")
                    Text("Flutter remains the behavior reference while the main app UI is migrated screen by screen.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                agentAPIKey = (try? AgentCredentialStore().loadAPIKey()) ?? ""
            }
            .onDisappear {
                try? AgentCredentialStore().save(apiKey: agentAPIKey)
            }
        }
        .preferredColorScheme(
            appearance == "dark" ? .dark : appearance == "light" ? .light : nil
        )
        .tint(DesignTokens.accent)
    }

    @ViewBuilder
    private var pushTokenRow: some View {
        let token = pushToken
        if token.isEmpty {
            Label("Push token unavailable", systemImage: "bell.slash")
                .foregroundStyle(.secondary)
            Button("Register for push notifications") {
                AppDelegate.requestPushRegistration()
            }
        } else {
            LabeledContent("Push token") {
                Text(token)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Button("Copy token") {
                UIPasteboard.general.string = token
            }
            Button("Refresh token") {
                AppDelegate.requestPushRegistration()
            }
        }
    }

    private var pushToken: String {
        UserDefaults.standard.string(forKey: AppGroup.pushTokenKey) ?? ""
    }
}

private struct PrivateKeysView: View {
    private let store: PrivateKeyStore
    @State private var records: [PrivateKeyRecord] = []
    @State private var editingRecord: PrivateKeyRecord?
    @State private var showingEditor = false
    @State private var errorMessage: String?

    init(store: PrivateKeyStore = .live) {
        self.store = store
    }

    var body: some View {
        List {
            if records.isEmpty {
                ContentUnavailableView(
                    "No private keys",
                    systemImage: "key",
                    description: Text("Add a private key to reuse it across server connections.")
                )
            } else {
                ForEach(records) { record in
                    Button {
                        editingRecord = record
                        showingEditor = true
                    } label: {
                        Label {
                            VStack(alignment: .leading) {
                                Text(record.name)
                                Text(record.id)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "key.fill")
                                .foregroundStyle(DesignTokens.accent)
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Delete", role: .destructive) {
                            delete(record)
                        }
                    }
                }
            }
        }
        .navigationTitle("Private keys")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editingRecord = nil
                    showingEditor = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add private key")
            }
        }
        .task { load() }
        .sheet(isPresented: $showingEditor) {
            PrivateKeyEditorView(record: editingRecord, store: store) {
                load()
            }
        }
        .alert(
            "Private key error",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown private key error")
        }
    }

    private func load() {
        do {
            records = try store.records()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ record: PrivateKeyRecord) {
        do {
            try store.delete(record)
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct PrivateKeyEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let record: PrivateKeyRecord?
    let store: PrivateKeyStore
    let onSaved: () -> Void
    @State private var name: String
    @State private var key: String
    @State private var passphrase: String
    @State private var showingImporter = false
    @State private var errorMessage: String?

    init(
        record: PrivateKeyRecord?,
        store: PrivateKeyStore,
        onSaved: @escaping () -> Void
    ) {
        self.record = record
        self.store = store
        self.onSaved = onSaved
        _name = State(initialValue: record?.name ?? "")
        let secret = record.flatMap { try? store.secret(for: $0) }
        _key = State(initialValue: secret?.key ?? "")
        _passphrase = State(initialValue: secret?.passphrase ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextEditor(text: $key)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 180)
                    SecureField("Passphrase (optional)", text: $passphrase)
                    Button("Import from file") { showingImporter = true }
                } header: {
                    Text("Private key")
                } footer: {
                    Text("The key and passphrase are stored in the iOS Keychain.")
                }
            }
            .navigationTitle(record == nil ? "Add private key" : "Edit private key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(
                            name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do {
                    let file = try FileHandle(forReadingFrom: url)
                    defer { try? file.close() }
                    let data = try file.read(upToCount: 1_048_577) ?? Data()
                    guard data.count <= 1_048_576 else {
                        throw PrivateKeyStoreError.invalidSecret
                    }
                    guard let content = String(data: data, encoding: .utf8) else {
                        throw PrivateKeyStoreError.invalidSecret
                    }
                    key = content
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .alert(
                "Private key error",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Unknown private key error")
            }
        }
        .tint(DesignTokens.accent)
    }

    private func save() {
        let keyID = record?.id ?? UUID().uuidString
        let keyRecord = PrivateKeyRecord(
            id: keyID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: record?.createdAt ?? Date()
        )
        do {
            try store.save(
                record: keyRecord,
                key: key,
                passphrase: passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct BackupView: View {
    @ObservedObject var serverViewModel: ServerListViewModel
    @State private var exportURL: URL?
    @State private var errorMessage: String?
    @State private var showingImporter = false
    @State private var showingBulkImporter = false
    @State private var bulkImportMessage: String?

    var body: some View {
        Form {
            Section {
                Text("Export your server configuration without credentials. Passwords and private keys remain in Keychain and are never included.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Create backup") { createBackup() }
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Share backup", systemImage: "square.and.arrow.up")
                    }
                }
                Button("Restore backup") { showingImporter = true }
            } header: {
                Text("Backup")
            }

            Section {
                Button("Bulk import servers") { showingBulkImporter = true }
            } header: {
                Text("Import")
            } footer: {
                Text("Import a JSON file: [{\"name\",\"ip\",\"port\",\"user\",\"pwd\",\"keyId\",\"tags\",\"alterUrl\",\"autoConnect\"}]. keyId is the name of a saved private key.")
            }

            Section("Servers") {
                LabeledContent("Server count", value: "\(serverViewModel.servers.count)")
            }

            if let bulkImportMessage {
                Section {
                    Label(bulkImportMessage, systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
            }
        }
        .navigationTitle("Backup")
        .task { await serverViewModel.loadIfNeeded() }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task {
                do {
                    try await serverViewModel.importBackup(from: url)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        .fileImporter(
            isPresented: $showingBulkImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task {
                do {
                    let count = try await serverViewModel.importBulkServers(from: url)
                    bulkImportMessage = "Imported \(count) servers."
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        .alert(
            "Backup error",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown backup error")
        }
    }

    private func createBackup() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(serverViewModel.servers)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("serverbox-backup-\(UUID().uuidString).json")
            try data.write(to: url, options: .atomic)
            exportURL = url
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
