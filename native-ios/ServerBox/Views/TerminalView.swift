import SwiftUI

@MainActor
final class TerminalViewModel: ObservableObject {
    enum State: Equatable {
        case connecting
        case connected
        case disconnected
        case failed(String)
    }

    @Published private(set) var output = ""
    @Published var input = ""
    @Published private(set) var state: State = .connecting

    private let openSession: () async throws -> SSHTerminalSession
    private var session: SSHTerminalSession?
    private var outputTask: Task<Void, Never>?
    private var outputParser = TerminalOutputParser()

    init(openSession: @escaping () async throws -> SSHTerminalSession) {
        self.openSession = openSession
    }

    func start() async {
        guard session == nil else { return }
        state = .connecting

        do {
            let session = try await openSession()
            self.session = session
            state = .connected
            let output = await session.output
            outputTask = Task { [weak self] in
                do {
                    for try await chunk in output {
                        guard !Task.isCancelled else { return }
                        self?.append(chunk)
                    }
                    if !Task.isCancelled {
                        self?.state = .disconnected
                    }
                } catch {
                    if !Task.isCancelled {
                        self?.state = .failed(error.localizedDescription)
                    }
                }
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func sendLine() async {
        let line = input
        input = ""
        await send(line + "\n")
    }

    func send(_ value: String) async {
        guard let session else { return }
        do {
            try await session.send(value)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func close() async {
        outputTask?.cancel()
        outputTask = nil
        if let session {
            await session.close()
        }
        session = nil
        state = .disconnected
    }

    private func append(_ chunk: String) {
        let cleanedChunk = outputParser.consume(chunk)
        guard !cleanedChunk.isEmpty else { return }

        output += cleanedChunk
        if output.count > 80_000 {
            output = String(output.suffix(80_000))
        }
    }
}

struct TerminalView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: TerminalViewModel
    @FocusState private var inputFocused: Bool

    init(openSession: @escaping () async throws -> SSHTerminalSession) {
        _viewModel = StateObject(wrappedValue: TerminalViewModel(openSession: openSession))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                terminalOutput
                Divider()
                commandBar
            }
            .background(Color.black)
            .navigationTitle("SSH Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        Task {
                            await viewModel.close()
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .principal) {
                    Label(stateTitle, systemImage: stateIcon)
                        .font(.caption)
                        .foregroundStyle(stateColor)
                }
            }
            .task {
                await viewModel.start()
                inputFocused = true
            }
            .onDisappear {
                Task { await viewModel.close() }
            }
        }
        .tint(DesignTokens.accent)
    }

    private var terminalOutput: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if viewModel.output.isEmpty {
                        Text("Connecting...")
                    } else {
                        Text(verbatim: viewModel.output)
                    }
                }
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.green)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DesignTokens.spaceM)
                .id("terminal-output")
            }
            .background(Color.black)
            .onChange(of: viewModel.output) { _, _ in
                proxy.scrollTo("terminal-output", anchor: .bottom)
            }
        }
    }

    private var commandBar: some View {
        HStack(spacing: DesignTokens.spaceS) {
            TextField("Command", text: $viewModel.input)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit {
                    Task { await viewModel.sendLine() }
                }

            Button {
                Task { await viewModel.sendLine() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(viewModel.input.isEmpty || viewModel.state != .connected)

            Button("Ctrl-C") {
                Task { await viewModel.send("\u{3}") }
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .disabled(viewModel.state != .connected)
        }
        .padding(DesignTokens.spaceS)
        .background(.regularMaterial)
    }

    private var stateTitle: LocalizedStringKey {
        switch viewModel.state {
        case .connecting:
            return "Connecting"
        case .connected:
            return "Connected"
        case .disconnected:
            return "Disconnected"
        case .failed:
            return "Failed"
        }
    }

    private var stateIcon: String {
        switch viewModel.state {
        case .connecting:
            return "arrow.triangle.2.circlepath"
        case .connected:
            return "checkmark.circle.fill"
        case .disconnected:
            return "circle"
        case .failed:
            return "exclamationmark.circle.fill"
        }
    }

    private var stateColor: Color {
        switch viewModel.state {
        case .connecting:
            return .orange
        case .connected:
            return .green
        case .disconnected:
            return .secondary
        case .failed:
            return .red
        }
    }
}
