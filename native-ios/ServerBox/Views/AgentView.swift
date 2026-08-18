import Foundation
import SwiftUI

struct AgentMessage: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let role: Role
    let content: String
    let toolCallID: String?
    let toolName: String?
    let toolCalls: [AgentToolCall]?

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        toolCallID: String? = nil,
        toolName: String? = nil,
        toolCalls: [AgentToolCall]? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.toolCalls = toolCalls
    }

    enum Role: String, Codable, Sendable {
        case user
        case assistant
        case tool
    }

    static func == (lhs: AgentMessage, rhs: AgentMessage) -> Bool {
        lhs.id == rhs.id &&
            lhs.role == rhs.role &&
            lhs.content == rhs.content &&
            lhs.toolCallID == rhs.toolCallID &&
            lhs.toolName == rhs.toolName &&
            lhs.toolCalls == rhs.toolCalls
    }
}

struct AgentToolCall: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let arguments: String

    init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

struct AgentSession: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var messages: [AgentMessage]
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, messages: [AgentMessage] = [], updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.messages = messages
        self.updatedAt = updatedAt
    }
}

actor AgentConversationStore {
    static let live = AgentConversationStore()

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            self.fileURL = applicationSupport
                .appendingPathComponent("ServerBox", isDirectory: true)
                .appendingPathComponent("agent-sessions.json")
        }
    }

    func load() throws -> [AgentSession] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([AgentSession].self, from: Data(contentsOf: fileURL))
    }

    func save(_ sessions: [AgentSession]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(sessions).write(to: fileURL, options: .atomic)
    }
}

struct AgentConfiguration: Sendable {
    var baseURL: String
    var apiKey: String
    var model: String
}

enum AgentToolExecutor {
    static let readOnlyPrefixes = [
        "ls", "cat", "ps", "df", "free", "top", "uptime", "whoami",
        "hostname", "uname", "echo", "pwd", "id", "date", "du", "stat",
        "systemctl status", "docker ps", "docker logs", "git status", "head", "tail", "grep",
    ]

    static let dangerousKeywords = [
        "rm ", "shutdown", "reboot", "suspend", "dd ", "mkfs", "format",
        "chmod -R", "chown -R", "--no-preserve-root", ":(){", "kill -9", "pkill",
    ]

    static func risk(of command: String) -> AgentToolRisk {
        let lower = command.lowercased()
        for keyword in dangerousKeywords where lower.contains(keyword) {
            return .dangerous
        }
        for prefix in readOnlyPrefixes where lower.hasPrefix(prefix) {
            return .safe
        }
        return .caution
    }
}

enum AgentToolRisk {
    case safe
    case caution
    case dangerous
}

struct PendingAgentToolCall: Identifiable, Sendable {
    let id: String
    let name: String
    let arguments: String
    let risk: AgentToolRisk
}

@MainActor
final class AgentViewModel: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var activeSessionID: UUID?
    @Published private(set) var isSending = false
    @Published var errorMessage: String?
    @Published var pendingToolCall: PendingAgentToolCall?
    @Published var autoRunSafeCommands = false
    @Published var selectedServerID: UUID?

    private let service: AgentService
    private let store: AgentConversationStore
    private var isLoaded = false
    private var isToolLoopRunning = false
    private var lastConfiguration: AgentConfiguration?

    private let runShellCommand: (UUID, String) async throws -> String
    private let readRemoteFile: (UUID, String) async throws -> String
    private let writeRemoteFile: (UUID, String, String) async throws -> Void

    init(
        service: AgentService = AgentService(),
        store: AgentConversationStore = .live,
        runShellCommand: @escaping (UUID, String) async throws -> String,
        readRemoteFile: @escaping (UUID, String) async throws -> String,
        writeRemoteFile: @escaping (UUID, String, String) async throws -> Void
    ) {
        self.service = service
        self.store = store
        self.runShellCommand = runShellCommand
        self.readRemoteFile = readRemoteFile
        self.writeRemoteFile = writeRemoteFile
    }

    var activeMessages: [AgentMessage] {
        guard let activeSessionID,
              let session = sessions.first(where: { $0.id == activeSessionID }) else {
            return []
        }
        return session.messages
    }

    func load() async {
        guard !isLoaded else { return }
        do {
            sessions = try await store.load()
            if sessions.isEmpty {
                let session = AgentSession(name: "对话")
                sessions = [session]
                activeSessionID = session.id
                try await persistSessions()
            } else {
                activeSessionID = sessions.first?.id
            }
            isLoaded = true
        } catch {
            errorMessage = "无法恢复 Agent 会话。"
        }
    }

    func newSession() async {
        let session = AgentSession(name: "对话 \(sessions.count + 1)")
        sessions.append(session)
        activeSessionID = session.id
        await persistSessions()
    }

    func switchSession(_ id: UUID) {
        activeSessionID = id
        pendingToolCall = nil
    }

    func renameSession(_ id: UUID, name: String) async {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].name = name
        await persistSessions()
    }

    func deleteSession(_ id: UUID) async {
        sessions.removeAll { $0.id == id }
        if activeSessionID == id {
            activeSessionID = sessions.first?.id
        }
        await persistSessions()
    }

    func clearActiveSession() async {
        guard let activeSessionID,
              let index = sessions.firstIndex(where: { $0.id == activeSessionID }) else { return }
        sessions[index].messages.removeAll()
        await persistSessions()
    }

    func send(
        _ prompt: String,
        configuration: AgentConfiguration
    ) async {
        if !isLoaded {
            await load()
        }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        guard let activeSessionID else { return }

        isSending = true
        defer { isSending = false }

        appendMessage(AgentMessage(role: .user, content: text))
        await persistSessions()

        await runToolLoop(configuration: configuration)
    }

    func approveToolCall(_ call: PendingAgentToolCall) async {
        pendingToolCall = nil
        await executeTool(call)
    }

    func rejectToolCall(_ call: PendingAgentToolCall) async {
        pendingToolCall = nil
        appendMessage(
            AgentMessage(
                role: .tool,
                content: "工具调用被用户拒绝：\(call.name) \(call.arguments)",
                toolCallID: call.id,
                toolName: call.name
            )
        )
        await persistSessions()
        await continueToolLoop()
    }

    private func runToolLoop(configuration: AgentConfiguration) async {
        lastConfiguration = configuration
        isToolLoopRunning = true
        defer { isToolLoopRunning = false }
        await requestCompletion(configuration: configuration)
    }

    private func continueToolLoop() async {
        guard let configuration = lastConfiguration else { return }
        guard isToolLoopRunning else { return }
        await requestCompletion(configuration: configuration)
    }

    private func requestCompletion(configuration: AgentConfiguration) async {
        do {
            let response = try await service.send(
                messages: activeMessages,
                configuration: configuration
            )
            if !response.content.isEmpty {
                appendMessage(AgentMessage(role: .assistant, content: response.content))
                await persistSessions()
            }
            if let toolCalls = response.toolCalls, !toolCalls.isEmpty {
                let assistantToolMessage = AgentMessage(
                    role: .assistant,
                    content: response.content,
                    toolCalls: toolCalls
                )
                appendMessage(assistantToolMessage)
                await persistSessions()
                for call in toolCalls {
                    let risk = AgentToolExecutor.risk(of: "\(call.name) \(call.arguments)")
                    let pending = PendingAgentToolCall(
                        id: call.id,
                        name: call.name,
                        arguments: call.arguments,
                        risk: risk
                    )
                    if autoRunSafeCommands, risk == .safe, let serverID = selectedServerID {
                        await executeTool(pending, serverID: serverID)
                    } else {
                        pendingToolCall = pending
                        return
                    }
                }
                if pendingToolCall == nil {
                    await continueToolLoop()
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func executeTool(_ call: PendingAgentToolCall) async {
        await executeTool(call, serverID: selectedServerID)
    }

    private func executeTool(_ call: PendingAgentToolCall, serverID: UUID?) async {
        guard let serverID else {
            appendMessage(
                AgentMessage(
                    role: .tool,
                    content: "工具执行失败：未选择服务器。",
                    toolCallID: call.id,
                    toolName: call.name
                )
            )
            await persistSessions()
            return
        }
        let result: String
        do {
            switch call.name {
            case "run_shell_command":
                let args = try JSONSerialization.jsonObject(
                    with: Data(call.arguments.utf8)
                ) as? [String: Any]
                let command = args?["command"] as? String ?? ""
                guard !command.isEmpty else {
                    throw AgentToolError.invalidArguments
                }
                let output = try await runShellCommand(serverID, command)
                result = String(output.prefix(32 * 1024))
            case "read_file":
                let args = try JSONSerialization.jsonObject(
                    with: Data(call.arguments.utf8)
                ) as? [String: Any]
                let path = args?["path"] as? String ?? ""
                guard !path.isEmpty else {
                    throw AgentToolError.invalidArguments
                }
                let output = try await readRemoteFile(serverID, path)
                result = String(output.prefix(128 * 1024))
            case "write_file":
                let args = try JSONSerialization.jsonObject(
                    with: Data(call.arguments.utf8)
                ) as? [String: Any]
                let path = args?["path"] as? String ?? ""
                let content = args?["content"] as? String ?? ""
                guard !path.isEmpty else {
                    throw AgentToolError.invalidArguments
                }
                try await writeRemoteFile(serverID, path, content)
                result = "文件已写入：\(path)"
            default:
                throw AgentToolError.unknownTool(call.name)
            }
            appendMessage(
                AgentMessage(
                    role: .tool,
                    content: result,
                    toolCallID: call.id,
                    toolName: call.name
                )
            )
        } catch {
            appendMessage(
                AgentMessage(
                    role: .tool,
                    content: "工具执行失败：\(error.localizedDescription)",
                    toolCallID: call.id,
                    toolName: call.name
                )
            )
        }
        await persistSessions()
        await continueToolLoop()
    }

    private func appendMessage(_ message: AgentMessage) {
        guard let activeSessionID,
              let index = sessions.firstIndex(where: { $0.id == activeSessionID }) else {
            return
        }
        sessions[index].messages.append(message)
        sessions[index].updatedAt = Date()
        if sessions[index].messages.count > 200 {
            sessions[index].messages.removeFirst(sessions[index].messages.count - 200)
        }
    }

    private func persistSessions() async {
        do {
            try await store.save(sessions)
        } catch {
            errorMessage = "无法保存 Agent 会话。"
        }
    }
}

enum AgentToolError: LocalizedError, Sendable {
    case invalidArguments
    case unknownTool(String)
    case serverUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "工具参数无效。"
        case .unknownTool(let name):
            return "未知工具：\(name)。"
        case .serverUnavailable:
            return "所选服务器不可用。"
        }
    }
}

struct AgentService: Sendable {
    func send(
        messages: [AgentMessage],
        configuration: AgentConfiguration
    ) async throws -> AgentResponse {
        guard !configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentError.missingAPIKey
        }
        let rawBaseURL = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawURL = URL(string: rawBaseURL),
              (rawURL.scheme == "http" || rawURL.scheme == "https") else {
            throw AgentError.invalidEndpoint
        }
        let path = rawURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedBaseURL = rawBaseURL.hasSuffix("/")
            ? rawBaseURL
            : rawBaseURL + "/"
        guard let baseURL = URL(string: normalizedBaseURL),
              (baseURL.scheme == "http" || baseURL.scheme == "https"),
              let url = path.hasSuffix("chat/completions")
                  ? rawURL
                  : URL(string: "chat/completions", relativeTo: baseURL) else {
            throw AgentError.invalidEndpoint
        }

        struct RequestMessage: Encodable {
            let role: String
            let content: String
            let name: String?
            let toolCallID: String?
            let toolCalls: [ToolCallRequest]?

            enum CodingKeys: String, CodingKey {
                case role
                case content
                case name
                case toolCallID = "tool_call_id"
                case toolCalls = "tool_calls"
            }
        }
        struct ToolCallRequest: Encodable {
            let id: String
            let type: String
            let function: FunctionCall
        }
        struct FunctionCall: Encodable {
            let name: String
            let arguments: String
        }
        struct ToolDefinition: Encodable {
            let type: String
            let function: ToolFunction
        }
        struct ToolFunction: Encodable {
            let name: String
            let description: String
            let parameters: [String: AnyEncodable]
        }
        struct AnyEncodable: Encodable {
            let value: Any
            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                if let value = value as? String {
                    try container.encode(value)
                } else if let value = value as? [String: Any] {
                    try container.encode(value.mapValues { AnyEncodable(value: $0) })
                } else if let value = value as? [Any] {
                    try container.encode(value.map { AnyEncodable(value: $0) })
                } else if let value = value as? Bool {
                    try container.encode(value)
                } else if let value = value as? Int {
                    try container.encode(value)
                } else {
                    try container.encodeNil()
                }
            }
        }
        struct Request: Encodable {
            let model: String
            let messages: [RequestMessage]
            let tools: [ToolDefinition]
        }
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let content: String?
                    let toolCalls: [ToolCallResponse]?

                    enum CodingKeys: String, CodingKey {
                        case content
                        case toolCalls = "tool_calls"
                    }
                }
                struct ToolCallResponse: Decodable {
                    let id: String
                    let function: Function
                    struct Function: Decodable {
                        let name: String
                        let arguments: String
                    }
                }
                let message: Message
            }
            let choices: [Choice]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")

        let toolDefinitions = [
            ToolDefinition(
                type: "function",
                function: ToolFunction(
                    name: "run_shell_command",
                    description: "在选定的服务器上执行 shell 命令并返回输出。",
                    parameters: [
                        "type": AnyEncodable(value: "object"),
                        "properties": AnyEncodable(value: [
                            "command": ["type": "string", "description": "要执行的命令"]
                        ]),
                        "required": AnyEncodable(value: ["command"]),
                    ]
                )
            ),
            ToolDefinition(
                type: "function",
                function: ToolFunction(
                    name: "read_file",
                    description: "读取选定服务器上的文本文件内容。",
                    parameters: [
                        "type": AnyEncodable(value: "object"),
                        "properties": AnyEncodable(value: [
                            "path": ["type": "string", "description": "远程文件路径"]
                        ]),
                        "required": AnyEncodable(value: ["path"]),
                    ]
                )
            ),
            ToolDefinition(
                type: "function",
                function: ToolFunction(
                    name: "write_file",
                    description: "向选定服务器上的文件写入内容。",
                    parameters: [
                        "type": AnyEncodable(value: "object"),
                        "properties": AnyEncodable(value: [
                            "path": ["type": "string", "description": "远程文件路径"],
                            "content": ["type": "string", "description": "要写入的内容"],
                        ]),
                        "required": AnyEncodable(value: ["path", "content"]),
                    ]
                )
            ),
        ]

        let requestMessages = messages.map { message in
            RequestMessage(
                role: message.role.rawValue,
                content: message.content,
                name: message.toolName,
                toolCallID: message.toolCallID,
                toolCalls: message.toolCalls?.map { call in
                    ToolCallRequest(
                        id: call.id,
                        type: "function",
                        function: FunctionCall(name: call.name, arguments: call.arguments)
                    )
                }
            )
        }
        request.httpBody = try JSONEncoder().encode(
            Request(
                model: configuration.model,
                messages: requestMessages,
                tools: toolDefinitions
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw AgentError.requestFailed(String(decoding: data, as: UTF8.self))
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let choice = decoded.choices.first else {
            throw AgentError.emptyResponse
        }
        let toolCalls = choice.message.toolCalls?.map { call in
            AgentToolCall(
                id: call.id,
                name: call.function.name,
                arguments: call.function.arguments
            )
        }
        return AgentResponse(
            content: choice.message.content ?? "",
            toolCalls: toolCalls
        )
    }
}

struct AgentResponse: Sendable {
    let content: String
    let toolCalls: [AgentToolCall]?
}

enum AgentError: LocalizedError, Equatable, Sendable {
    case missingAPIKey
    case invalidEndpoint
    case requestFailed(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "使用前请在设置中配置 API 密钥。"
        case .invalidEndpoint:
            "请输入有效的 OpenAI 兼容 API 地址。"
        case .requestFailed(let message):
            message.isEmpty ? "Agent 请求失败。" : message
        case .emptyResponse:
            "Agent 未返回任何响应。"
        }
    }
}

struct AgentView: View {
    let onSettings: () -> Void
    let servers: [ServerConfiguration]
    let runShellCommand: (UUID, String) async throws -> String
    let readRemoteFile: (UUID, String) async throws -> String
    let writeRemoteFile: (UUID, String, String) async throws -> Void

    @StateObject private var viewModel: AgentViewModel
    @AppStorage("native.agent.baseURL") private var baseURL = "https://api.openai.com/v1/"
    @AppStorage("native.agent.model") private var model = "gpt-4o-mini"
    @AppStorage("native.agent.autoRunSafe") private var autoRunSafeCommands = false
    @State private var apiKey = ""
    @State private var prompt = ""
    @State private var showingSessions = false

    init(
        onSettings: @escaping () -> Void,
        servers: [ServerConfiguration],
        runShellCommand: @escaping (UUID, String) async throws -> String,
        readRemoteFile: @escaping (UUID, String) async throws -> String,
        writeRemoteFile: @escaping (UUID, String, String) async throws -> Void
    ) {
        self.onSettings = onSettings
        self.servers = servers
        self.runShellCommand = runShellCommand
        self.readRemoteFile = readRemoteFile
        self.writeRemoteFile = writeRemoteFile
        _viewModel = StateObject(
            wrappedValue: AgentViewModel(
                runShellCommand: runShellCommand,
                readRemoteFile: readRemoteFile,
                writeRemoteFile: writeRemoteFile
            )
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if viewModel.activeMessages.isEmpty {
                    ContentUnavailableView(
                        "Agent",
                        systemImage: "sparkles",
                        description: Text("询问关于你的服务器和命令的问题。Agent 可以执行命令、读写文件。")
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: DesignTokens.spaceM) {
                                ForEach(viewModel.activeMessages) { message in
                                    AgentMessageBubble(message: message)
                                        .id(message.id)
                                }
                                if let pending = viewModel.pendingToolCall {
                                    toolApprovalCard(pending)
                                        .id("pending-tool")
                                }
                                if viewModel.isSending {
                                    ProgressView()
                                        .padding(.horizontal, DesignTokens.spaceM)
                                }
                            }
                            .padding(DesignTokens.spaceM)
                        }
                        .onChange(of: viewModel.activeMessages.count) { _, _ in
                            if let id = viewModel.activeMessages.last?.id {
                                withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                            }
                        }
                    }
                }

                Divider()
                HStack(alignment: .bottom, spacing: DesignTokens.spaceS) {
                    TextField("询问 Agent", text: $prompt, axis: .vertical)
                        .lineLimit(1...5)
                        .textInputAutocapitalization(.sentences)
                        .onSubmit { send() }
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(
                        prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || viewModel.isSending
                    )
                    .accessibilityLabel("发送消息")
                }
                .padding(DesignTokens.spaceM)
            }
            .navigationTitle("Agent")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onSettings) {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("设置")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("新建会话") {
                            Task { await viewModel.newSession() }
                        }
                        Button("清空当前会话") {
                            Task { await viewModel.clearActiveSession() }
                        }
                        Divider()
                        Picker("服务器", selection: Binding(
                            get: { viewModel.selectedServerID },
                            set: { viewModel.selectedServerID = $0 }
                        )) {
                            Text("未选择").tag(UUID?.none)
                            ForEach(servers) { server in
                                Text(server.name).tag(UUID?.some(server.id))
                            }
                        }
                        Divider()
                        Toggle("自动运行安全命令", isOn: Binding(
                            get: { viewModel.autoRunSafeCommands },
                            set: { viewModel.autoRunSafeCommands = $0 }
                        ))
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Agent 选项")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSessions = true
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .accessibilityLabel("会话历史")
                }
            }
            .sheet(isPresented: $showingSessions) {
                AgentSessionListView(viewModel: viewModel)
            }
            .alert(
                "Agent 错误",
                isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { if !$0 { viewModel.errorMessage = nil } }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "未知 Agent 错误")
            }
            .task {
                apiKey = (try? AgentCredentialStore().loadAPIKey()) ?? ""
                viewModel.autoRunSafeCommands = autoRunSafeCommands
                await viewModel.load()
            }
            .onDisappear {
                autoRunSafeCommands = viewModel.autoRunSafeCommands
            }
        }
        .tint(DesignTokens.accent)
    }

    private func toolApprovalCard(_ pending: PendingAgentToolCall) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.spaceS) {
            HStack {
                Label(pending.name, systemImage: "wrench.and.screwdriver")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(riskTitle(pending.risk))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(riskColor(pending.risk))
            }
            Text(pending.arguments)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            HStack {
                Button("拒绝") {
                    Task { await viewModel.rejectToolCall(pending) }
                }
                .buttonStyle(.bordered)
                Button("允许") {
                    Task { await viewModel.approveToolCall(pending) }
                }
                .buttonStyle(.borderedProminent)
                .tint(pending.risk == .dangerous ? .red : DesignTokens.accent)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(DesignTokens.spaceM)
        .background(DesignTokens.surface)
        .clipShape(.rect(cornerRadius: DesignTokens.radiusM))
    }

    private func riskTitle(_ risk: AgentToolRisk) -> String {
        switch risk {
        case .safe: return "安全"
        case .caution: return "需确认"
        case .dangerous: return "高风险"
        }
    }

    private func riskColor(_ risk: AgentToolRisk) -> Color {
        switch risk {
        case .safe: return .green
        case .caution: return .orange
        case .dangerous: return .red
        }
    }

    private func send() {
        let currentAPIKey: String
        do {
            currentAPIKey = try AgentCredentialStore().loadAPIKey() ?? ""
        } catch {
            currentAPIKey = apiKey
        }
        let configuration = AgentConfiguration(baseURL: baseURL, apiKey: currentAPIKey, model: model)
        let text = prompt
        prompt = ""
        Task { await viewModel.send(text, configuration: configuration) }
    }
}

private struct AgentSessionListView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: AgentViewModel
    @State private var renamingSession: AgentSession?

    var body: some View {
        NavigationStack {
            List {
                ForEach(viewModel.sessions) { session in
                    Button {
                        viewModel.switchSession(session.id)
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .foregroundStyle(DesignTokens.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.name)
                                Text("\(session.messages.count) 条消息")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if viewModel.activeSessionID == session.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(DesignTokens.accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("删除", role: .destructive) {
                            Task { await viewModel.deleteSession(session.id) }
                        }
                        Button("重命名") {
                            renamingSession = session
                        }
                    }
                }
            }
            .navigationTitle("会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("新建") {
                        Task { await viewModel.newSession() }
                    }
                }
            }
            .sheet(item: $renamingSession) { session in
                AgentSessionRenameView(session: session) { name in
                    Task { await viewModel.renameSession(session.id, name: name) }
                }
            }
        }
        .tint(DesignTokens.accent)
    }
}

private struct AgentSessionRenameView: View {
    @Environment(\.dismiss) private var dismiss
    let session: AgentSession
    let onRename: (String) -> Void
    @State private var name: String

    init(session: AgentSession, onRename: @escaping (String) -> Void) {
        self.session = session
        self.onRename = onRename
        _name = State(initialValue: session.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("会话名称", text: $name)
            }
            .navigationTitle("重命名会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onRename(name.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .tint(DesignTokens.accent)
    }
}

private struct AgentMessageBubble: View {
    let message: AgentMessage

    var body: some View {
        HStack {
            if message.role == .assistant || message.role == .tool {
                avatar
            }
            VStack(alignment: .leading, spacing: 4) {
                if let toolName = message.toolName {
                    Text(toolName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DesignTokens.accent)
                }
                Text(message.content.isEmpty ? "..." : message.content)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(message.role == .tool ? .system(.caption, design: .monospaced) : .body)
                    .textSelection(.enabled)
            }
            .padding(DesignTokens.spaceM)
            .background(bubbleColor)
            .clipShape(.rect(cornerRadius: DesignTokens.radiusM))
            if message.role == .user { avatar }
        }
    }

    private var avatar: some View {
        Image(systemName: message.role == .user ? "person.fill" : "sparkles")
            .foregroundStyle(message.role == .user ? DesignTokens.accent : .secondary)
            .frame(width: 24)
    }

    private var bubbleColor: Color {
        switch message.role {
        case .user:
            return DesignTokens.accent.opacity(0.16)
        case .tool:
            return .black.opacity(0.06)
        case .assistant:
            return DesignTokens.surface
        }
    }
}
