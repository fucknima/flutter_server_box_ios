import Foundation
import SwiftUI

@MainActor
final class SFTPViewModel: ObservableObject {
    @Published private(set) var files: [RemoteFile] = []
    @Published private(set) var path = "/"
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var preview: RemoteFilePreview?

    private let listDirectory: (String) async throws -> [RemoteFile]
    private let readFile: (String) async throws -> String

    init(
        listDirectory: @escaping (String) async throws -> [RemoteFile],
        readFile: @escaping (String) async throws -> String
    ) {
        self.listDirectory = listDirectory
        self.readFile = readFile
    }

    func load(path: String? = nil) async {
        let requestedPath = path ?? self.path
        isLoading = true
        defer { isLoading = false }

        do {
            files = try await listDirectory(requestedPath)
            self.path = requestedPath
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func open(_ file: RemoteFile) async {
        if file.isDirectory {
            await load(path: file.path)
            return
        }

        do {
            let content = try await readFile(file.path)
            preview = RemoteFilePreview(file: file, content: content)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func goUp() async {
        guard path != "/" else { return }
        let components = path.split(separator: "/")
        let parent = components.count <= 1
            ? "/"
            : "/" + components.dropLast().joined(separator: "/")
        await load(path: parent)
    }
}

struct RemoteFilePreview: Identifiable {
    let file: RemoteFile
    let content: String

    var id: String { file.id }
}

struct SFTPView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: SFTPViewModel

    init(
        listDirectory: @escaping (String) async throws -> [RemoteFile],
        readFile: @escaping (String) async throws -> String
    ) {
        _viewModel = StateObject(
            wrappedValue: SFTPViewModel(
                listDirectory: listDirectory,
                readFile: readFile
            )
        )
    }

    var body: some View {
        NavigationStack {
            List {
                if viewModel.path != "/" {
                    Button {
                        Task { await viewModel.goUp() }
                    } label: {
                        Label("..", systemImage: "arrow.up.left")
                    }
                }

                if viewModel.isLoading && viewModel.files.isEmpty {
                    ProgressView("Loading directory...")
                } else if viewModel.files.isEmpty {
                    ContentUnavailableView(
                        "Empty directory",
                        systemImage: "folder",
                        description: Text("There are no files to display here.")
                    )
                } else {
                    ForEach(viewModel.files) { file in
                        Button {
                            Task { await viewModel.open(file) }
                        } label: {
                            fileRow(file)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(viewModel.path == "/" ? "SFTP" : viewModel.path)
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
                    .accessibilityLabel("Refresh directory")
                }
            }
            .task {
                await viewModel.load(path: "/")
            }
            .alert(
                "SFTP error",
                isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { isPresented in
                        if !isPresented { viewModel.errorMessage = nil }
                    }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "Unknown SFTP error")
            }
            .sheet(item: $viewModel.preview) { preview in
                RemoteFilePreviewView(preview: preview)
            }
        }
        .tint(DesignTokens.accent)
    }

    private func fileRow(_ file: RemoteFile) -> some View {
        HStack(spacing: DesignTokens.spaceS) {
            Image(systemName: file.isDirectory ? "folder.fill" : "doc.text")
                .foregroundStyle(file.isDirectory ? .orange : DesignTokens.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .lineLimit(1)
                HStack(spacing: DesignTokens.spaceS) {
                    if let size = file.size {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    }
                    if let modifiedAt = file.modifiedAt {
                        Text(modifiedAt, style: .date)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if file.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct RemoteFilePreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let preview: RemoteFilePreview

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(preview.content)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignTokens.spaceM)
            }
            .navigationTitle(preview.file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
