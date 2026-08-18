import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct LocalFileEntry: Identifiable, Hashable, Sendable {
    let url: URL
    let isDirectory: Bool
    let size: Int64
    let modifiedAt: Date?

    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

@MainActor
final class LocalFilesViewModel: ObservableObject {
    @Published private(set) var directory: URL
    @Published private(set) var entries: [LocalFileEntry] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var editorFile: LocalFileEntry?

    private let fileManager: FileManager

    init(
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.directory = directory
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    func load() {
        isLoading = true
        defer { isLoading = false }

        do {
            let urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .fileSizeKey,
                    .contentModificationDateKey,
                ],
                options: [.skipsHiddenFiles]
            )
            entries = try urls.map { url in
                let values = try url.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .fileSizeKey,
                    .contentModificationDateKey,
                ])
                return LocalFileEntry(
                    url: url,
                    isDirectory: values.isDirectory == true,
                    size: Int64(values.fileSize ?? 0),
                    modifiedAt: values.contentModificationDate
                )
            }.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            errorMessage = nil
        } catch {
            entries = []
            errorMessage = error.localizedDescription
        }
    }

    func open(_ entry: LocalFileEntry) {
        if entry.isDirectory {
            directory = entry.url
            load()
        } else {
            editorFile = entry
        }
    }

    func openFile(at url: URL) {
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let entry = LocalFileEntry(
                url: url,
                isDirectory: values.isDirectory == true,
                size: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate
            )
            open(entry)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func goUp() {
        let root = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard directory.path != root.path else { return }
        directory = directory.deletingLastPathComponent()
        load()
    }

    func delete(_ entry: LocalFileEntry) {
        do {
            try fileManager.removeItem(at: entry.url)
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createItem(named name: String, directory: Bool) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              !trimmedName.contains("/"),
              trimmedName != ".",
              trimmedName != ".." else {
            errorMessage = LocalFileError.invalidName.localizedDescription
            return
        }

        do {
            let root = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .resolvingSymlinksInPath()
            let safeDirectory = self.directory.resolvingSymlinksInPath()
            guard safeDirectory.path == root.path || safeDirectory.path.hasPrefix(root.path + "/") else {
                throw LocalFileError.invalidName
            }
            let destination = safeDirectory.appendingPathComponent(trimmedName).standardizedFileURL
            if directory {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
            } else {
                guard fileManager.createFile(atPath: destination.path, contents: Data()) else {
                    throw LocalFileError.createFailed
                }
            }
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rename(_ entry: LocalFileEntry, to name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              !trimmedName.contains("/"),
              trimmedName != ".",
              trimmedName != ".." else {
            errorMessage = LocalFileError.invalidName.localizedDescription
            return
        }

        do {
            let root = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .resolvingSymlinksInPath()
            let parent = entry.url
                .deletingLastPathComponent()
                .resolvingSymlinksInPath()
            guard parent.path == root.path || parent.path.hasPrefix(root.path + "/") else {
                throw LocalFileError.invalidName
            }
            let destination = parent.appendingPathComponent(trimmedName).standardizedFileURL
            try fileManager.moveItem(
                at: entry.url,
                to: destination
            )
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importFile(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let destination = directory.appendingPathComponent(url.lastPathComponent)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: url, to: destination)
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct LocalFilesView: View {
    let onSettings: () -> Void
    let requestedFileURL: URL?
    let onConsumeRequestedFile: () -> Void
    @StateObject private var viewModel = LocalFilesViewModel()
    @State private var fileToRename: LocalFileEntry?
    @State private var createKind: LocalCreateKind?
    @State private var showingImporter = false

    init(
        onSettings: @escaping () -> Void,
        requestedFileURL: URL? = nil,
        onConsumeRequestedFile: @escaping () -> Void = {}
    ) {
        self.onSettings = onSettings
        self.requestedFileURL = requestedFileURL
        self.onConsumeRequestedFile = onConsumeRequestedFile
    }

    var body: some View {
        NavigationStack {
            List {
                if viewModel.directory.path != documentDirectory.path {
                    Button {
                        viewModel.goUp()
                    } label: {
                        Label("..", systemImage: "arrow.up.left")
                    }
                }

                if viewModel.isLoading && viewModel.entries.isEmpty {
                    ProgressView("正在加载文件...")
                } else if viewModel.entries.isEmpty {
                    ContentUnavailableView(
                        "暂无本地文件",
                        systemImage: "folder",
                        description: Text("从文件标签页导入或创建文件。")
                    )
                } else {
                    ForEach(viewModel.entries) { entry in
                        Button { viewModel.open(entry) } label: {
                            fileRow(entry)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("删除", role: .destructive) {
                                viewModel.delete(entry)
                            }
                            Button("重命名") {
                                fileToRename = entry
                            }
                            .tint(.orange)
                        }
                    }
                }
            }
            .navigationTitle(viewModel.directory.lastPathComponent.isEmpty
                ? "文件"
                : viewModel.directory.lastPathComponent)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onSettings) {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("设置")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button("新建文件夹", systemImage: "folder.badge.plus") {
                            createKind = .folder
                        }
                        Button("新建文件", systemImage: "doc.badge.plus") {
                            createKind = .file
                        }
                        Divider()
                        Button("导入文件", systemImage: "square.and.arrow.down") {
                            showingImporter = true
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("创建或导入文件")

                    Button {
                        viewModel.load()
                    } label: {
                        if viewModel.isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(viewModel.isLoading)
                    .accessibilityLabel("刷新文件")
                }
            }
            .refreshable { viewModel.load() }
            .task { viewModel.load() }
            .onChange(of: requestedFileURL, initial: true) { _, url in
                guard let url else { return }
                viewModel.openFile(at: url)
                onConsumeRequestedFile()
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    viewModel.importFile(from: url)
                }
            }
            .sheet(item: $viewModel.editorFile) { entry in
                LocalTextEditorView(file: entry)
            }
            .sheet(item: $fileToRename) { entry in
                RenameLocalFileView(entry: entry) { name in
                    viewModel.rename(entry, to: name)
                }
            }
            .sheet(item: $createKind) { kind in
                LocalCreateItemView(kind: kind) { name in
                    viewModel.createItem(named: name, directory: kind == .folder)
                }
            }
            .alert(
                "文件错误",
                isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { if !$0 { viewModel.errorMessage = nil } }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "未知文件错误")
            }
        }
        .tint(DesignTokens.accent)
    }

    private var documentDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func fileRow(_ entry: LocalFileEntry) -> some View {
        HStack(spacing: DesignTokens.spaceS) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.text")
                .foregroundStyle(entry.isDirectory ? .orange : DesignTokens.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .lineLimit(1)
                if !entry.isDirectory {
                    Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct RenameLocalFileView: View {
    @Environment(\.dismiss) private var dismiss
    let entry: LocalFileEntry
    let onRename: (String) -> Void
    @State private var name: String

    init(entry: LocalFileEntry, onRename: @escaping (String) -> Void) {
        self.entry = entry
        self.onRename = onRename
        _name = State(initialValue: entry.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("名称", text: $name)
            }
            .navigationTitle("重命名")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onRename(name)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private enum LocalCreateKind: String, Identifiable {
    case folder
    case file

    var id: String { rawValue }
    var title: LocalizedStringKey { self == .folder ? "新建文件夹" : "新建文件" }
}

private struct LocalCreateItemView: View {
    @Environment(\.dismiss) private var dismiss
    let kind: LocalCreateKind
    let onCreate: (String) -> Void
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("名称", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        onCreate(name)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct LocalTextEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let file: LocalFileEntry
    @State private var content = ""
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("正在加载文件...")
                } else {
                    TextEditor(text: $content)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(DesignTokens.spaceS)
                }
            }
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(isLoading)
                }
            }
            .task { load() }
            .alert(
                "文件错误",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "未知文件错误")
            }
        }
    }

    private func load() {
        do {
            let values = try file.url.resourceValues(forKeys: [.fileSizeKey])
            guard values.fileSize ?? 0 <= 1_048_576 else {
                throw LocalFileError.fileTooLarge
            }
            content = try String(contentsOf: file.url, encoding: .utf8)
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func save() {
        do {
            try content.write(to: file.url, atomically: true, encoding: .utf8)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum LocalFileError: LocalizedError {
    case fileTooLarge
    case invalidName
    case createFailed

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            "此文件过大，无法在设备上编辑。"
        case .invalidName:
            "文件名不能包含路径分隔符或上级目录组件。"
        case .createFailed:
            "无法创建本地文件。"
        }
    }
}
