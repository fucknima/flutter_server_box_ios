import SwiftUI
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
                    NavigationLink("Private keys") {
                        PrivateKeysView(serverViewModel: serverViewModel)
                    }
                    NavigationLink("Backup") {
                        BackupView(serverViewModel: serverViewModel)
                    }
                }

                Section("Agent") {
                    TextField("API endpoint", text: $agentBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("API key", text: $agentAPIKey)
                    TextField("Model", text: $agentModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Use an OpenAI-compatible chat completions endpoint. The API key is stored in Keychain.")
                }

                Section("About") {
                    LabeledContent("Native UI", value: "SwiftUI")
                    LabeledContent("Watch", value: "Flutter retained")
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
}

private struct PrivateKeysView: View {
    @ObservedObject var serverViewModel: ServerListViewModel
    @State private var editingServer: ServerConfiguration?

    private var keyServers: [ServerConfiguration] {
        serverViewModel.servers.filter {
            if case .privateKey = $0.authentication { return true }
            return false
        }
    }

    var body: some View {
        List {
            if keyServers.isEmpty {
                ContentUnavailableView(
                    "No private keys",
                    systemImage: "key",
                    description: Text("Private keys are attached to server connections.")
                )
            } else {
                ForEach(keyServers) { server in
                    Button { editingServer = server } label: {
                        Label {
                            VStack(alignment: .leading) {
                                Text(server.name)
                                Text("\(server.username)@\(server.host)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "key.fill")
                                .foregroundStyle(DesignTokens.accent)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Private keys")
        .sheet(item: $editingServer) { server in
            ServerEditorView(server: server) { draft in
                try await serverViewModel.save(draft)
            }
        }
        .task { await serverViewModel.loadIfNeeded() }
    }
}

private struct BackupView: View {
    @ObservedObject var serverViewModel: ServerListViewModel
    @State private var exportText: String?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Text("Export your server configuration without credentials. Passwords and private keys remain in Keychain and are never included.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Create backup") { createBackup() }
                if let exportText {
                    ShareLink(item: exportText) {
                        Label("Share backup", systemImage: "square.and.arrow.up")
                    }
                }
            } header: {
                Text("Backup")
            }

            Section("Servers") {
                LabeledContent("Server count", value: "\(serverViewModel.servers.count)")
            }
        }
        .navigationTitle("Backup")
        .task { await serverViewModel.loadIfNeeded() }
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
            exportText = String(
                data: try encoder.encode(serverViewModel.servers),
                encoding: .utf8
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
