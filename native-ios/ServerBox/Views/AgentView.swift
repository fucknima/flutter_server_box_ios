import Foundation
import SwiftUI

struct AgentMessage: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let role: Role
    let content: String

    init(id: UUID = UUID(), role: Role, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }

    enum Role: String, Codable, Sendable {
        case user
        case assistant
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
                .appendingPathComponent("agent-conversation.json")
        }
    }

    func load() throws -> [AgentMessage] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([AgentMessage].self, from: Data(contentsOf: fileURL))
    }

    func save(_ messages: [AgentMessage]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(messages).write(to: fileURL, options: .atomic)
    }
}

struct AgentConfiguration: Sendable {
    var baseURL: String
    var apiKey: String
    var model: String
}

struct AgentService: Sendable {
    func send(
        messages: [AgentMessage],
        configuration: AgentConfiguration
    ) async throws -> String {
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
        }
        struct Request: Encodable {
            let model: String
            let messages: [RequestMessage]
        }
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            Request(
                model: configuration.model,
                messages: messages.map { RequestMessage(role: $0.role.rawValue, content: $0.content) }
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw AgentError.requestFailed(String(decoding: data, as: UTF8.self))
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let content = decoded.choices.first?.message.content,
              !content.isEmpty else {
            throw AgentError.emptyResponse
        }
        return content
    }
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

@MainActor
final class AgentViewModel: ObservableObject {
    @Published private(set) var messages: [AgentMessage] = []
    @Published private(set) var isSending = false
    @Published var errorMessage: String?

    private let service: AgentService
    private let store: AgentConversationStore
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var isLoaded = false

    init(
        service: AgentService = AgentService(),
        store: AgentConversationStore = .live
    ) {
        self.service = service
        self.store = store
    }

    func load() async {
        guard !isLoaded else { return }
        if let loadTask {
            await loadTask.value
            return
        }
        let generation = loadGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var didLoad = false
            do {
                let restored = try await self.store.load()
                guard self.loadGeneration == generation else { return }
                self.messages = Array(restored.suffix(200))
                self.errorMessage = nil
                didLoad = true
            } catch {
                guard self.loadGeneration == generation else { return }
                self.errorMessage = "无法恢复 Agent 对话记录。"
            }
            if self.loadGeneration == generation, didLoad {
                self.isLoaded = true
            }
            self.loadTask = nil
        }
        loadTask = task
        await task.value
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
        isSending = true
        defer { isSending = false }
        messages.append(AgentMessage(role: .user, content: text))
        trimHistory()
        await persist()

        do {
            let response = try await service.send(messages: messages, configuration: configuration)
            messages.append(AgentMessage(role: .assistant, content: response))
            trimHistory()
            await persist()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clear() {
        loadGeneration += 1
        loadTask?.cancel()
        loadTask = nil
        isLoaded = true
        messages.removeAll()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.store.save([])
            } catch {
                self.errorMessage = "无法清除 Agent 对话记录。"
            }
        }
    }

    private func persist() async {
        do {
            try await store.save(messages)
        } catch {
            errorMessage = "无法保存 Agent 对话记录。"
        }
    }

    private func trimHistory() {
        guard messages.count > 200 else { return }
        messages.removeFirst(messages.count - 200)
    }
}

struct AgentView: View {
    let onSettings: () -> Void
    @StateObject private var viewModel = AgentViewModel()
    @AppStorage("native.agent.baseURL") private var baseURL = "https://api.openai.com/v1/"
    @AppStorage("native.agent.model") private var model = "gpt-4o-mini"
    @State private var apiKey = ""
    @State private var prompt = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if viewModel.messages.isEmpty {
                    ContentUnavailableView(
                        "Agent",
                        systemImage: "sparkles",
                        description: Text("询问关于你的服务器和命令的问题。")
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: DesignTokens.spaceM) {
                                ForEach(viewModel.messages) { message in
                                    AgentMessageBubble(message: message)
                                        .id(message.id)
                                }
                                if viewModel.isSending {
                                    ProgressView()
                                        .padding(.horizontal, DesignTokens.spaceM)
                                }
                            }
                            .padding(DesignTokens.spaceM)
                        }
                        .onChange(of: viewModel.messages.count) { _, _ in
                            if let id = viewModel.messages.last?.id {
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
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isSending)
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
                    Button("清空", action: viewModel.clear)
                        .disabled(viewModel.messages.isEmpty || viewModel.isSending)
                }
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
                await viewModel.load()
            }
        }
        .tint(DesignTokens.accent)
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

private struct AgentMessageBubble: View {
    let message: AgentMessage

    var body: some View {
        HStack {
            if message.role == .assistant { avatar }
            Text(message.content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DesignTokens.spaceM)
                .background(message.role == .user ? DesignTokens.accent.opacity(0.16) : DesignTokens.surface)
                .clipShape(.rect(cornerRadius: DesignTokens.radiusM))
            if message.role == .user { avatar }
        }
    }

    private var avatar: some View {
        Image(systemName: message.role == .user ? "person.fill" : "sparkles")
            .foregroundStyle(message.role == .user ? DesignTokens.accent : .secondary)
            .frame(width: 24)
    }
}
