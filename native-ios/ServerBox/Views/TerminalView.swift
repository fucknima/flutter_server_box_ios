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
    @Published private(set) var commandHistory: [String] = []

    private let openSession: () async throws -> SSHTerminalSession
    private let initialCommand: String?
    private var session: SSHTerminalSession?
    private var outputTask: Task<Void, Never>?
    private var outputParser = TerminalOutputParser()
    private var lifecycleGeneration = 0
    private var lastTerminalSize: (columns: Int, rows: Int)?
    private var requestedTerminalSize: (columns: Int, rows: Int)?
    private var historyCursor = 0

    init(
        openSession: @escaping () async throws -> SSHTerminalSession,
        initialCommand: String? = nil
    ) {
        self.openSession = openSession
        self.initialCommand = initialCommand
    }

    func start() async {
        guard session == nil else { return }
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        lastTerminalSize = nil
        state = .connecting

        do {
            let session = try await openSession()
            guard generation == lifecycleGeneration, !Task.isCancelled else {
                await session.close()
                return
            }
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
            if let requestedTerminalSize {
                do {
                    try await session.resize(
                        columns: requestedTerminalSize.columns,
                        rows: requestedTerminalSize.rows
                    )
                    lastTerminalSize = requestedTerminalSize
                } catch {
                }
            }
            guard generation == lifecycleGeneration, !Task.isCancelled else {
                await session.close()
                return
            }
            if let initialCommand, !initialCommand.isEmpty {
                try await session.send(initialCommand + "\n")
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func sendLine() async {
        guard state == .connected else { return }
        let line = input
        input = ""
        if !line.isEmpty {
            commandHistory.removeAll { $0 == line }
            commandHistory.append(line)
            if commandHistory.count > 100 {
                commandHistory.removeFirst(commandHistory.count - 100)
            }
        }
        historyCursor = commandHistory.count
        await send(line + "\n")
    }

    func previousCommand() {
        guard !commandHistory.isEmpty else { return }
        historyCursor = max(0, historyCursor - 1)
        input = commandHistory[historyCursor]
    }

    func nextCommand() {
        guard !commandHistory.isEmpty else { return }
        historyCursor = min(commandHistory.count, historyCursor + 1)
        input = historyCursor == commandHistory.count ? "" : commandHistory[historyCursor]
    }

    func send(_ value: String) async {
        guard state == .connected else { return }
        guard let session else { return }
        do {
            try await session.send(value)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func sendControl(_ value: String) async {
        await send(value)
    }

    func resize(columns: Int, rows: Int) async {
        guard columns > 0, rows > 0 else { return }
        requestedTerminalSize = (columns, rows)
        guard let session else { return }
        guard lastTerminalSize?.columns != columns || lastTerminalSize?.rows != rows else {
            return
        }
        do {
            try await session.resize(columns: columns, rows: rows)
            lastTerminalSize = (columns, rows)
        } catch {
        }
    }

    func clearOutput() {
        output = ""
        outputParser = TerminalOutputParser()
    }

    func retry() async {
        await close()
        await start()
    }

    func close() async {
        lifecycleGeneration += 1
        outputTask?.cancel()
        outputTask = nil
        if let session {
            await session.close()
        }
        session = nil
        lastTerminalSize = nil
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

    init(
        initialCommand: String? = nil,
        openSession: @escaping () async throws -> SSHTerminalSession
    ) {
        _viewModel = StateObject(
            wrappedValue: TerminalViewModel(
                openSession: openSession,
                initialCommand: initialCommand
            )
        )
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    terminalOutput
                    if !enabledVirtKeys.isEmpty {
                        virtKeyBar
                    }
                    Divider()
                    commandBar
                }
                .onChange(of: geometry.size, initial: true) { _, size in
                    let columns = max(40, Int(size.width / 8))
                    let rows = max(8, Int(max(0, size.height - 64) / 18))
                    Task { await viewModel.resize(columns: columns, rows: rows) }
                }
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
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Clear output", systemImage: "trash") {
                            viewModel.clearOutput()
                        }
                        if case .failed = viewModel.state {
                            Button("Retry", systemImage: "arrow.clockwise") {
                                Task { await viewModel.retry() }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Terminal actions")
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
                .font(.system(size: 12 * SettingsStore.textFactor, design: .monospaced))
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

    private var enabledVirtKeys: [VirtKeyDefinition] {
        let catalog = VirtKeyCatalog.all
        let storedOrder = SettingsStore.virtKeyOrder
        let ordered = storedOrder.compactMap { id in catalog.first { $0.id == id } }
        let missing = catalog.filter { key in !storedOrder.contains(key.id) }
        let disabled = SettingsStore.virtKeyDisabled
        return (ordered + missing).filter { !disabled.contains($0.id) }
    }

    private var virtKeyBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignTokens.spaceS) {
                ForEach(enabledVirtKeys) { key in
                    Button {
                        Task { await viewModel.send(key.sequence) }
                    } label: {
                        Text(key.label)
                            .font(.system(.caption, design: .monospaced, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .disabled(viewModel.state != .connected)
                    .accessibilityLabel(key.id)
                }
            }
            .padding(.horizontal, DesignTokens.spaceS)
            .padding(.vertical, 4)
        }
        .background(Color.black)
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
                    Task { await viewModel.sendControl("\u{3}") }
                }
            .font(.caption)
            .buttonStyle(.bordered)
            .disabled(viewModel.state != .connected)

                Menu {
                    Button("Previous command") { viewModel.previousCommand() }
                    Button("Next command") { viewModel.nextCommand() }
                    Divider()
                    Button("Tab") { Task { await viewModel.sendControl("\t") } }
                    Button("Escape") { Task { await viewModel.sendControl("\u{1B}") } }
                    Button("Ctrl-D") { Task { await viewModel.sendControl("\u{4}") } }
                    Button("Ctrl-L") { Task { await viewModel.sendControl("\u{C}") } }
                    Button("Arrow up") { Task { await viewModel.sendControl("\u{1B}[A") } }
                    Button("Arrow down") { Task { await viewModel.sendControl("\u{1B}[B") } }
                } label: {
                Image(systemName: "keyboard")
            }
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
