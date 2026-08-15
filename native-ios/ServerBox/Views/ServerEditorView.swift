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
    @State private var statusURLText: String
    @State private var autoConnect: Bool
    @State private var validationMessage: String?
    @State private var isSaving = false

    private let existingServer: ServerConfiguration?
    private let onSave: (ServerEditorDraft) async throws -> Void

    init(
        server: ServerConfiguration? = nil,
        onSave: @escaping (ServerEditorDraft) async throws -> Void
    ) {
        existingServer = server
        self.onSave = onSave
        _name = State(initialValue: server?.name ?? "")
        _host = State(initialValue: server?.host ?? "")
        _portText = State(initialValue: String(server?.port ?? 22))
        _username = State(initialValue: server?.username ?? "root")
        _authenticationMethod = State(
            initialValue: Self.authenticationMethod(for: server?.authentication)
        )
        _secret = State(initialValue: "")
        _passphrase = State(initialValue: "")
        _statusURLText = State(initialValue: server?.statusURL?.absoluteString ?? "")
        _autoConnect = State(initialValue: server?.autoConnect ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("SSH connection") {
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
                } footer: {
                    Text("Credentials are stored in the iOS Keychain and are never written to the server file.")
                }

                Section("Status monitor (optional)") {
                    TextField("https://example.com/status", text: $statusURLText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("If supplied, the existing HTTP monitor is refreshed alongside the SSH connection.")
                }

                Section("Connection") {
                    Toggle("Connect automatically", isOn: $autoConnect)
                    Text("Unknown SSH host keys require an explicit trust action from the server card.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
                TextEditor(text: $secret)
                    .frame(minHeight: 130)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(.secondary.opacity(0.25))
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

            let authentication: ServerAuthenticationReference
            switch authenticationMethod {
            case .password:
                authentication = .password
            case .privateKey:
                let keyID: String
                if let existingAuthentication = existingServer?.authentication,
                   case .privateKey(let existingKeyID) = existingAuthentication {
                    keyID = existingKeyID
                } else {
                    keyID = UUID().uuidString
                }
                authentication = .privateKey(id: keyID)
            }

            let configuration = ServerConfiguration(
                id: existingServer?.id ?? UUID(),
                name: trimmedName,
                host: trimmedHost,
                port: port,
                username: trimmedUsername,
                authentication: authentication,
                tags: existingServer?.tags ?? [],
                alternateEndpoint: existingServer?.alternateEndpoint,
                autoConnect: autoConnect,
                jumpServerIDs: existingServer?.jumpServerIDs ?? [],
                proxyCommand: existingServer?.proxyCommand,
                customCommands: existingServer?.customCommands ?? [:],
                environment: existingServer?.environment ?? [:],
                customSystem: existingServer?.customSystem ?? .automatic,
                disabledStatusTypes: existingServer?.disabledStatusTypes ?? [],
                statusURL: statusURL,
                isEnabled: existingServer?.isEnabled ?? true,
                createdAt: existingServer?.createdAt ?? Date(),
                knownHostKey: existingServer?.knownHostKey
            )

            let credential: ServerCredentialInput?
            switch authenticationMethod {
            case .password:
                credential = secret.isEmpty ? nil : .password(secret)
            case .privateKey:
                credential = secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : .privateKey(
                        secret,
                        passphrase: passphrase.isEmpty ? nil : passphrase
                    )
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
