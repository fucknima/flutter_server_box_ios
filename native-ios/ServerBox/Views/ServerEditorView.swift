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
                    TextField("显示名称", text: $name)
                        .textInputAutocapitalization(.words)

                    TextField("主机或 IP 地址", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("端口", text: $portText)
                        .keyboardType(.numberPad)

                    TextField("用户名", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Picker("认证方式", selection: $authenticationMethod) {
                        ForEach(AuthenticationMethod.allCases) { method in
                            Text(method.title).tag(method)
                        }
                    }

                    credentialFields
                } header: {
                    Text("SSH 连接")
                } footer: {
                    Text("凭据存储在 iOS 钥匙串中，不会写入服务器配置文件。")
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
                    Text("状态监控（可选）")
                } footer: {
                    Text("填写后，HTTP 监控会与 SSH 连接一起刷新。Logo URL 可包含 {DIST} 和 {BRIGHT}，它们会被替换为服务器发行版和主题亮度。")
                }

                Section {
                    Toggle("自动连接", isOn: $autoConnect)
                    Toggle("启用", isOn: $isEnabled)
                    Text("未知 SSH 主机密钥需要在服务器卡片上明确确认信任。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("连接")
                }

                Section("标签") {
                    TextField("以逗号分隔的标签", text: $tagsText)
                }

                Section {
                    Picker("远程系统", selection: $customSystem) {
                        Text("自动").tag(RemoteSystem.automatic)
                        Text("Unix").tag(RemoteSystem.unix)
                        Text("Windows").tag(RemoteSystem.windows)
                    }

                    TextField("备用主机", text: $alternateHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("备用端口", text: $alternatePortText)
                        .keyboardType(.numberPad)
                    TextField("备用用户名", text: $alternateUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if !availableServers.isEmpty {
                        DisclosureGroup("跳板主机") {
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

                    TextField("代理命令", text: $proxyCommand, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("高级连接")
                } footer: {
                    Text("跳板主机按顺序尝试。iOS 上不支持代理命令。")
                }

                Section {
                    Toggle("启用 Proxmox 工具", isOn: $pveEnabled)
                } header: {
                    Text("远程工具")
                } footer: {
                    Text("仅当服务器提供 Proxmox pvesh 命令时启用。")
                }

                Section {
                    TextEditor(text: $customCommandsText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 80)
                        .overlay(alignment: .topLeading) {
                            if customCommandsText.isEmpty {
                                Text("自定义命令 JSON")
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
                                Text("环境变量 JSON")
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                } header: {
                    Text("自定义数据")
                } footer: {
                    Text("两个字段都使用键值为字符串的 JSON 对象。")
                }

                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(existingServer == nil ? "添加服务器" : "编辑服务器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
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
                existingServer == nil ? "密码" : "密码（留空以保留当前密码）",
                text: $secret
            )
        case .privateKey:
            VStack(alignment: .leading, spacing: 8) {
                if !privateKeyRecords.isEmpty {
                    Picker("已保存的私钥", selection: $selectedPrivateKeyID) {
                        Text("内嵌私钥").tag(nil as String?)
                        ForEach(privateKeyRecords) { record in
                            Text(record.name).tag(record.id as String?)
                        }
                    }
                }
                if let selectedPrivateKeyID,
                   let record = privateKeyRecords.first(where: { $0.id == selectedPrivateKeyID }) {
                    Label("正在使用 \(record.name)", systemImage: "key.fill")
                        .foregroundStyle(.secondary)
                } else {
                    TextEditor(text: $secret)
                        .frame(minHeight: 130)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(.secondary.opacity(0.25))
                        }
                }
                SecureField("口令（可选）", text: $passphrase)
            }
        }
    }

    private func save() {
        guard !isSaving else { return }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else {
            validationMessage = "请输入此服务器的名称。"
            return
        }
        guard let port = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            validationMessage = "请输入有效端口。"
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
            return "密码"
        case .privateKey:
            return "私钥"
        }
    }
}

private enum ServerEditorError: LocalizedError {
    case invalidJSONMap

    var errorDescription: String? {
        "自定义命令和环境变量必须是有效的 JSON 对象。"
    }
}
