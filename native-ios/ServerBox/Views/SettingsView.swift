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
                Section("外观") {
                    Picker("外观", selection: $appearance) {
                        Text("系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }
                }

                Section("首页标签") {
                    Toggle("SSH", isOn: $sshTabEnabled)
                    Toggle("文件", isOn: $filesTabEnabled)
                    Toggle("代码片段", isOn: $snippetsTabEnabled)
                    Toggle("Agent", isOn: $agentTabEnabled)
                    Text("服务器始终启用。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("ServerBox") {
                    NavigationLink("连接统计") {
                        ConnectionStatsView(viewModel: ConnectionStatsViewModel())
                    }
                    NavigationLink("服务器发现") {
                        ServerDiscoveryView(serverViewModel: serverViewModel)
                    }
                    NavigationLink("私钥") {
                        PrivateKeysView()
                    }
                    NavigationLink("备份") {
                        BackupView(serverViewModel: serverViewModel)
                    }
                }

                Section {
                    pushTokenRow
                } header: {
                    Text("iOS 推送")
                } footer: {
                    Text("将推送令牌用于你自己的推送服务。自行编译的版本无法使用项目推送服务。")
                }

                Section("SSH 终端") {
                    NavigationLink("虚拟按键") {
                        VirtKeysView()
                    }
                }

                Section("高级") {
                    NavigationLink("编辑原始设置") {
                        RawSettingsEditorView()
                    }
                }

                Section {
                    TextField("API 端点", text: $agentBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("API 密钥", text: $agentAPIKey)
                    TextField("模型", text: $agentModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Agent")
                } footer: {
                    Text("使用兼容 OpenAI 的聊天补全接口。API 密钥存储在钥匙串中。")
                }

                Section("关于") {
                    LabeledContent("原生界面", value: "SwiftUI")
                    LabeledContent("小组件", value: "WidgetKit")
                    Text("主界面逐屏迁移中，Flutter 仍是行为参考。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
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
            Label("无法获取推送令牌", systemImage: "bell.slash")
                .foregroundStyle(.secondary)
            Button("注册推送通知") {
                AppDelegate.requestPushRegistration()
            }
        } else {
            LabeledContent("推送令牌") {
                Text(token)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Button("复制令牌") {
                UIPasteboard.general.string = token
            }
            Button("刷新令牌") {
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
                    "暂无私钥",
                    systemImage: "key",
                    description: Text("添加私钥后即可在多个服务器连接中复用。")
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
                        Button("删除", role: .destructive) {
                            delete(record)
                        }
                    }
                }
            }
        }
        .navigationTitle("私钥")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editingRecord = nil
                    showingEditor = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("添加私钥")
            }
        }
        .task { load() }
        .sheet(isPresented: $showingEditor) {
            PrivateKeyEditorView(record: editingRecord, store: store) {
                load()
            }
        }
        .alert(
            "私钥错误",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "未知私钥错误")
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
                    TextField("名称", text: $name)
                    TextEditor(text: $key)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 180)
                    SecureField("口令（可选）", text: $passphrase)
                    Button("从文件导入") { showingImporter = true }
                } header: {
                    Text("私钥")
                } footer: {
                    Text("私钥和口令存储在 iOS 钥匙串中。")
                }
            }
            .navigationTitle(record == nil ? "添加私钥" : "编辑私钥")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
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
                "私钥错误",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "未知私钥错误")
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
                Text("导出服务器配置（不含凭据）。密码和私钥保留在钥匙串中，绝不包含在导出内容中。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("创建备份") { createBackup() }
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("分享备份", systemImage: "square.and.arrow.up")
                    }
                }
                Button("恢复备份") { showingImporter = true }
            } header: {
                Text("备份")
            }

            Section {
                Button("批量导入服务器") { showingBulkImporter = true }
            } header: {
                Text("导入")
            } footer: {
                Text("导入 JSON 文件：[{\"name\",\"ip\",\"port\",\"user\",\"pwd\",\"keyId\",\"tags\",\"alterUrl\",\"autoConnect\"}]。keyId 为已保存私钥的名称。")
            }

            Section("服务器") {
                LabeledContent("服务器数量", value: "\(serverViewModel.servers.count)")
            }

            if let bulkImportMessage {
                Section {
                    Label(bulkImportMessage, systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
            }
        }
        .navigationTitle("备份")
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
                    bulkImportMessage = "已导入 \(count) 台服务器。"
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        .alert(
            "备份错误",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "未知备份错误")
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
