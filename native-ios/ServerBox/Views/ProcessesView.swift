import Foundation
import SwiftUI

@MainActor
final class ProcessesViewModel: ObservableObject {
    @Published private(set) var processes: [RemoteProcess] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var processToTerminate: RemoteProcess?

    private let listProcesses: () async throws -> [RemoteProcess]
    private let terminateProcess: (RemoteProcess, ProcessSignal) async throws -> Void

    init(
        listProcesses: @escaping () async throws -> [RemoteProcess],
        terminateProcess: @escaping (RemoteProcess, ProcessSignal) async throws -> Void
    ) {
        self.listProcesses = listProcesses
        self.terminateProcess = terminateProcess
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            processes = try await listProcesses()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func terminate(signal: ProcessSignal) async {
        guard let process = processToTerminate else { return }
        do {
            try await terminateProcess(process, signal)
            processToTerminate = nil
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ProcessesView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: ProcessesViewModel

    init(
        listProcesses: @escaping () async throws -> [RemoteProcess],
        terminateProcess: @escaping (RemoteProcess, ProcessSignal) async throws -> Void
    ) {
        _viewModel = StateObject(
            wrappedValue: ProcessesViewModel(
                listProcesses: listProcesses,
                terminateProcess: terminateProcess
            )
        )
    }

    var body: some View {
        NavigationStack {
            List(viewModel.processes) { process in
                Button {
                    viewModel.processToTerminate = process
                } label: {
                    processRow(process)
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if viewModel.isLoading && viewModel.processes.isEmpty {
                    ProgressView("Loading processes...")
                } else if !viewModel.isLoading && viewModel.processes.isEmpty {
                    ContentUnavailableView(
                        "No processes",
                        systemImage: "cpu",
                        description: Text("The server returned no process rows.")
                    )
                }
            }
            .navigationTitle("Processes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await viewModel.load() }
                    } label: {
                        if viewModel.isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(viewModel.isLoading)
                    .accessibilityLabel("Refresh processes")
                }
            }
            .task {
                await viewModel.load()
            }
            .confirmationDialog(
                "Terminate process?",
                isPresented: Binding(
                    get: { viewModel.processToTerminate != nil },
                    set: { isPresented in
                        if !isPresented { viewModel.processToTerminate = nil }
                    }
                )
            ) {
                Button("Terminate", role: .destructive) {
                    Task { await viewModel.terminate(signal: .terminate) }
                }
                Button("Force kill", role: .destructive) {
                    Task { await viewModel.terminate(signal: .kill) }
                }
                Button("Cancel", role: .cancel) {
                    viewModel.processToTerminate = nil
                }
            } message: {
                if let process = viewModel.processToTerminate {
                    Text("PID \(process.pid): \(process.command)")
                }
            }
            .alert(
                "Process error",
                isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { isPresented in
                        if !isPresented { viewModel.errorMessage = nil }
                    }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "Unknown process error")
            }
        }
        .tint(DesignTokens.accent)
    }

    private func processRow(_ process: RemoteProcess) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(process.command)
                    .font(.system(.subheadline, design: .monospaced, weight: .medium))
                    .lineLimit(2)
                Spacer()
                Text("#\(process.pid)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: DesignTokens.spaceM) {
                Label(process.user, systemImage: "person")
                Label(String(format: "%.1f%% CPU", process.cpuPercent), systemImage: "cpu")
                Label(String(format: "%.1f%% MEM", process.memoryPercent), systemImage: "memorychip")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}
