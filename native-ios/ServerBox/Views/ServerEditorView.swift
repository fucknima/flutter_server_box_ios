import SwiftUI

struct ServerEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var host: String
    @State private var portText: String
    @State private var username: String
    @State private var authenticationMethod: AuthenticationMethod
    @State private var secret: String
    @State private var passphrase: String
    @State private var selectedPrivateKeyID: String?
    @State private var privateKeyRecords: [PrivateKeyRecord]
    @State private var statusURLText: String
    @State private var logoURLText: String
    @State private var autoConnect: Bool
    @State private var isEnabled: Bool
    @State private var tagsText: String
    @State private var alternateHost: String
    @State private var alternatePortText: String
    @State private var alternateUsername: String
    @State private var proxyCommand: String
    @State private var selectedJumpServerIDs: [UUID]
    @State private var customCommandsText: String
    @State private var environmentText: String
    @State private var customSystem: RemoteSystem
    @State private var pveEnabled: Bool
    @State private var validationMessage: String?
    @State private var isSaving = false

    private let existingServer: ServerConfiguration?
    private let availableServers: [ServerConfiguration]
    private let onSave: (ServerEditorDraft) async throws -> Void
    private let privateKeyStore = PrivateKeyStore.live

    init(
        server: ServerConfiguration? = nil,
        availableServers: [ServerConfiguration] = [],
        onSave: @escaping (ServerEditorDraft) async throws -> Void
    ) {
        existingServer = server
        self.availableServers = availableServers.filter { $0.id != server?.id }
        self.onSave = onSave
        let existingKeyID: String?
        if let authentication = server?.authentication,
           case .privateKey(let id) = authentication {
            existingKeyID = id
        } else {
            existingKeyID = nil
        }
        let keyStore = PrivateKeyStore.live
        let savedKeys = (try? keyStore.records()) ?? []
        let selectedKeyID = existingKeyID.flatMap { id in
            savedKeys.contains(where: { $0.id == id }) ? id : nil
        }
        let savedSecret = selectedKeyID.flatMap { id in
            savedKeys.first(where: { $0.id == id }).flatMap {
                try? keyStore.secret(for: $0)
            }
        }
        _name = State(initialValue: server?.name ?? "")
        _host = State(initialValue: server?.host ?? "")
        _portText = State(initialValue: String(server?.port ?? 22))
        _username = State(initialValue: server?.username ?? "root")
        _authenticationMethod = State(
            initialValue: Self.authenticationMethod(for: server?.authentication)
        )
        _secret = State(initialValue: savedSecret?.key ?? "")
        _passphrase = State(initialValue: savedSecret?.passphrase ?? "")
        _selectedPrivateKeyID = State(initialValue: selectedKeyID)
        _privateKeyRecords = State(initialValue: savedKeys)
        _statusURLText = State(initialValue: server?.statusURL?.absoluteString ?? "")
        _logoURLText = State(initialValue: server?.logoURL?.absoluteString ?? "")
        _autoConnect = State(initialValue: server?.autoConnect ?? true)
        _isEnabled = State(initialValue: server?.isEnabled ?? true)
        _tagsText = State(initialValue: server?.tags.joined(separator: ", ") ?? "")
        _alternateHost = State(initialValue: server?.alternateEndpoint?.host ?? "")
        _alternatePortText = State(initialValue: server.map { String($0.alternateEndpoint?.port ?? 22) } ?? "22")
        _alternateUsername = State(initialValue: server?.alternateEndpoint?.username ?? "")
        _proxyCommand = State(initialValue: server?.proxyCommand ?? "")
        _selectedJumpServerIDs = State(initialValue: server?.normalizedJumpServerIDs ?? [])
        _customCommandsText = State(initialValue: Self.jsonText(server?.customCommands ?? [:]))
        _environmentText = State(initialValue: Self.jsonText(server?.environment ?? [:]))
        _customSystem = State(initialValue: server?.customSystem ?? .automatic)
        _pveEnabled = State(initialValue: server?.pveEnabled ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Display name", text: $name)
                        .textInputAutocapitalization(.words)

                    TextField("Host or IP address", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Port", text: $portText)
                        .keyboardType(.numberPad)

                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Picker("Authentication", selection: $authenticationMethod) {
                        ForEach(AuthenticationMethod.allCases) { method in
                            Text(method.title).tag(method)
                        }
                    }

                    credentialFields
                } header: {
                    Text("SSH connection")
                } footer: {
                    Text("Credentials are stored in the iOS Keychain and are never written to the server file.")
                }

                Section {
                    TextField("https://example.com/status", text: $statusURLText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("https://example.com/logo.png", text: $logoURLText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Status monitor (optional)")
                } footer: {
                    Text("If supplied, the existing HTTP monitor is refreshed alongside the SSH connection. The logo URL may contain {DIST} and {BRIGHT}, which are replaced with the server distribution and theme brightness.")
                }

                Section {
                    Toggle("Connect automatically", isOn: $autoConnect)
                    Toggle("Enabled", isOn: $isEnabled)
                    Text("Unknown SSH host keys require an explicit trust action from the server card.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Connection")
                }

                Section("Tags") {
                    TextField("Comma-separated tags", text: $tagsText)
                }

                Section {
                    Picker("Remote system", selection: $customSystem) {
                        Text("Automatic").tag(RemoteSystem.automatic)
                        Text("Unix").tag(RemoteSystem.unix)
                        Text("Windows").tag(RemoteSystem.windows)
                    }

                    TextField("Alternate host", text: $alternateHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Alternate port", text: $alternatePortText)
                        .keyboardType(.numberPad)
                    TextField("Alternate username", text: $alternateUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if !availableServers.isEmpty {
                        DisclosureGroup("Jump hosts") {
                            ForEach(availableServers) { jumpServer in
                                Toggle(jumpServer.name, isOn: Binding(
                                    get: { selectedJumpServerIDs.contains(jumpServer.id) },
                                    set: { enabled in
                                        if enabled {
                                            guard selectedJumpServerIDs.count < 2,
                                                  !selectedJumpServerIDs.contains(jumpServer.id) else { return }
                                            selectedJumpServerIDs.append(jumpServer.id)
                                        } else {
                                            selectedJumpServerIDs.removeAll { $0 == jumpServer.id }
                                        }
                                    }
                                ))
                                .disabled(
                                    !selectedJumpServerIDs.contains(jumpServer.id)
                                        && selectedJumpServerIDs.count >= 2
                                )
                            }
                        }
                    }

                    TextField("Proxy command", text: $proxyCommand, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Advanced connection")
                } footer: {
                    Text("Jump hosts are tried in order. Proxy commands are not supported on iOS.")
                }

                Section {
                    Toggle("Enable Proxmox tools", isOn: $pveEnabled)
                } header: {
                    Text("Remote tools")
                } footer: {
                    Text("Only enable this for a server that exposes the Proxmox pvesh command.")
                }

                Section {
                    TextEditor(text: $customCommandsText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 80)
                        .overlay(alignment: .topLeading) {
                            if customCommandsText.isEmpty {
                                Text("Custom commands JSON")
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                    TextEditor(text: $environmentText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 80)
                        .overlay(alignment: .topLeading) {
                            if environmentText.isEmpty {
                                Text("Environment JSON")
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                } header: {
                    Text("Custom data")
                } footer: {
                    Text("Both fields use a JSON object with string keys and values.")
                }

                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(existingServer == nil ? "Add server" : "Edit server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onChange(of: selectedPrivateKeyID) { _, keyID in
                guard let keyID,
                      let record = privateKeyRecords.first(where: { $0.id == keyID }),
                      let savedSecret = try? privateKeyStore.secret(for: record) else {
                    if keyID == nil {
                        secret = ""
                        passphrase = ""
                    }
                    return
                }
                secret = savedSecret.key
                passphrase = savedSecret.passphrase ?? ""
            }
            .onChange(of: authenticationMethod) { _, method in
                secret = ""
                passphrase = ""
                if method == .password {
                    selectedPrivateKeyID = nil
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
    }

    @ViewBuilder
    private var credentialFields: some View {
        switch authenticationMethod {
        case .password:
            SecureField(
                existingServer == nil ? "Password" : "Password (leave blank to keep current)",
                text: $secret
            )
        case .privateKey:
            VStack(alignment: .leading, spacing: 8) {
                if !privateKeyRecords.isEmpty {
                    Picker("Saved private key", selection: $selectedPrivateKeyID) {
                        Text("Inline private key").tag(nil as String?)
                        ForEach(privateKeyRecords) { record in
                            Text(record.name).tag(record.id as String?)
                        }
                    }
                }
                if let selectedPrivateKeyID,
                   let record = privateKeyRecords.first(where: { $0.id == selectedPrivateKeyID }) {
                    Label("Using \(record.name)", systemImage: "key.fill")
                        .foregroundStyle(.secondary)
                } else {
                    TextEditor(text: $secret)
                        .frame(minHeight: 130)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(.secondary.opacity(0.25))
                        }
                }
                SecureField("Passphrase (optional)", text: $passphrase)
            }
        }
    }

    private func save() {
        guard !isSaving else { return }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else {
            validationMessage = "Enter a name for this server."
            return
        }
        guard let port = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            validationMessage = "Enter a valid port."
            return
        }

        do {
            let statusURL: URL?
            if statusURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                statusURL = nil
            } else {
                statusURL = try MonitorEndpoint.normalizedURL(from: statusURLText)
            }

            let logoURL: URL?
            let trimmedLogo = logoURLText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLogo.isEmpty {
                logoURL = nil
            } else if let parsed = URL(string: trimmedLogo),
                      let scheme = parsed.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" {
                logoURL = parsed
            } else {
                throw ServerConfigurationError.invalidLogoURL
            }

            let alternateEndpoint: AlternateEndpoint?
            let trimmedAlternateHost = alternateHost.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedAlternateHost.isEmpty {
                alternateEndpoint = nil
            } else {
                guard let alternatePort = Int(alternatePortText),
                      (1...65_535).contains(alternatePort) else {
                    throw ServerConfigurationError.invalidPort
                }
                alternateEndpoint = AlternateEndpoint(
                    host: trimmedAlternateHost,
                    port: alternatePort,
                    username: alternateUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? trimmedUsername
                        : alternateUsername.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }

            let customCommands = try Self.decodeStringMap(customCommandsText)
            let environment = try Self.decodeStringMap(environmentText)

            let authentication: ServerAuthenticationReference
            switch authenticationMethod {
            case .password:
                authentication = .password
            case .privateKey:
                let keyID = selectedPrivateKeyID ?? existingPrivateKeyID ?? UUID().uuidString
                authentication = .privateKey(id: keyID)
            }

            let configuration = ServerConfiguration(
                id: existingServer?.id ?? UUID(),
                name: trimmedName,
                host: trimmedHost,
                port: port,
                username: trimmedUsername,
                authentication: authentication,
                tags: tagsText
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty },
                alternateEndpoint: alternateEndpoint,
                autoConnect: autoConnect,
                jumpServerIDs: selectedJumpServerIDs,
                proxyCommand: proxyCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : proxyCommand.trimmingCharacters(in: .whitespacesAndNewlines),
                customCommands: customCommands,
                environment: environment,
                customSystem: customSystem,
                pveEnabled: pveEnabled,
                disabledStatusTypes: existingServer?.disabledStatusTypes ?? [],
                statusURL: statusURL,
                logoURL: logoURL,
                isEnabled: isEnabled,
                createdAt: existingServer?.createdAt ?? Date(),
                knownHostKey: existingServer?.knownHostKey
            )

            let credential: ServerCredentialInput?
            switch authenticationMethod {
            case .password:
                credential = secret.isEmpty ? nil : .password(secret)
            case .privateKey:
                if selectedPrivateKeyID != nil {
                    // The selected key already lives in PrivateKeyStore; do not copy it
                    // into the per-server credential store.
                    credential = nil
                } else {
                    credential = secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? nil
                        : .privateKey(
                            secret,
                            passphrase: passphrase.isEmpty ? nil : passphrase
                        )
                }
            }

            try configuration.validate()
            validationMessage = nil
            isSaving = true

            Task {
                do {
                    try await onSave(ServerEditorDraft(configuration: configuration, credential: credential))
                    dismiss()
                } catch {
                    validationMessage = error.localizedDescription
                    isSaving = false
                }
            }
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private static func authenticationMethod(
        for reference: ServerAuthenticationReference?
    ) -> AuthenticationMethod {
        guard let reference else { return .password }
        switch reference {
        case .password:
            return .password
        case .privateKey:
            return .privateKey
        }
    }

    private var existingPrivateKeyID: String? {
        guard let authentication = existingServer?.authentication else { return nil }
        if case .privateKey(let id) = authentication { return id }
        return nil
    }

    private static func jsonText(_ values: [String: String]) -> String {
        guard let data = try? JSONEncoder().encode(values) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func decodeStringMap(_ text: String) throws -> [String: String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        guard let data = trimmed.data(using: .utf8),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else {
            throw ServerEditorError.invalidJSONMap
        }
        return values
    }
}

private enum AuthenticationMethod: String, CaseIterable, Identifiable {
    case password
    case privateKey

    var id: String { rawValue }

    var title: String {
        switch self {
        case .password:
            return "Password"
        case .privateKey:
            return "Private key"
        }
    }
}

private enum ServerEditorError: LocalizedError {
    case invalidJSONMap

    var errorDescription: String? {
        "Custom commands and environment must be valid JSON objects."
    }
}
