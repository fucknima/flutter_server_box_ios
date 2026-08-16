import Foundation
import SwiftUI

struct AgentMessage: Identifiable, Equatable, Sendable {
    let id = UUID()
    let role: Role
    let content: String

    enum Role: String, Sendable {
        case user
        case assistant
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
        guard let baseURL = URL(string: configuration.baseURL),
              let url = URL(string: "chat/completions", relativeTo: baseURL) else {
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
            "Configure an API key in Settings before using Agent."
        case .invalidEndpoint:
            "Enter a valid OpenAI-compatible API endpoint."
        case .requestFailed(let message):
            message.isEmpty ? "The Agent request failed." : message
        case .emptyResponse:
            "The Agent returned no response."
        }
    }
}

@MainActor
final class AgentViewModel: ObservableObject {
    @Published private(set) var messages: [AgentMessage] = []
    @Published private(set) var isSending = false
    @Published var errorMessage: String?

    private let service: AgentService

    init(service: AgentService = AgentService()) {
        self.service = service
    }

    func send(
        _ prompt: String,
        configuration: AgentConfiguration
    ) async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        messages.append(AgentMessage(role: .user, content: text))
        isSending = true
        defer { isSending = false }

        do {
            let response = try await service.send(messages: messages, configuration: configuration)
            messages.append(AgentMessage(role: .assistant, content: response))
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clear() {
        messages.removeAll()
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
                        description: Text("Ask questions about your servers and commands.")
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
                    TextField("Ask Agent", text: $prompt, axis: .vertical)
                        .lineLimit(1...5)
                        .textInputAutocapitalization(.sentences)
                        .onSubmit { send() }
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isSending)
                    .accessibilityLabel("Send message")
                }
                .padding(DesignTokens.spaceM)
            }
            .navigationTitle("Agent")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onSettings) {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear", action: viewModel.clear)
                        .disabled(viewModel.messages.isEmpty || viewModel.isSending)
                }
            }
            .alert(
                "Agent error",
                isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { if !$0 { viewModel.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "Unknown Agent error")
            }
            .task {
                apiKey = (try? AgentCredentialStore().loadAPIKey()) ?? ""
            }
        }
        .tint(DesignTokens.accent)
    }

    private func send() {
        let configuration = AgentConfiguration(baseURL: baseURL, apiKey: apiKey, model: model)
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
