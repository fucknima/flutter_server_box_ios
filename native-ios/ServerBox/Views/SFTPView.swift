import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SFTPViewModel: ObservableObject {
    @Published private(set) var files: [RemoteFile] = []
    @Published private(set) var path = "/"
    @Published private(set) var isLoading = false
    @Published private(set) var isMutating = false
    @Published var errorMessage: String?
    @Published var preview: RemoteFilePreview?

    private let listDirectory: (String) async throws -> [RemoteFile]
    private let readFile: (String) async throws -> String
    private let applyMutation: (SFTPRemoteMutation) async throws -> Void
    private let initialPath: () async throws -> String
    private var loadGeneration = 0
    private var previewGeneration = 0

    init(
        listDirectory: @escaping (String) async throws -> [RemoteFile],
        readFile: @escaping (String) async throws -> String,
        applyMutation: @escaping (SFTPRemoteMutation) async throws -> Void,
        initialPath: @escaping () async throws -> String
    ) {
        self.listDirectory = listDirectory
        self.readFile = readFile
        self.applyMutation = applyMutation
        self.initialPath = initialPath
    }

    func load(path: String? = nil) async {
        let requestedPath = path ?? self.path
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer {
            if generation == loadGeneration {
                isLoading = false
            }
        }

        do {
            let loadedFiles = try await listDirectory(requestedPath)
            guard generation == loadGeneration else { return }
            files = loadedFiles
            self.path = requestedPath
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadInitial() async {
        loadGeneration += 1
        let generation = loadGeneration
        let resolvedPath: String
        do {
            resolvedPath = try await initialPath()
        } catch is CancellationError {
            return
        } catch {
            resolvedPath = "/"
        }
        guard generation == loadGeneration else { return }
        await load(path: resolvedPath)
    }

    func goTo(path: String) async {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasPrefix("/"), !normalized.isEmpty else {
            errorMessage = "路径必须以 / 开头。"
            return
        }
        await load(path: normalized.replacingOccurrences(of: "/+", with: "/", options: .regularExpression))
    }

    func open(_ file: RemoteFile) async {
        if file.isDirectory {
            await load(path: file.path)
            return
        }

        previewGeneration += 1
        let generation = previewGeneration
        do {
            let content = try await readFile(file.path)
            guard generation == previewGeneration else { return }
            preview = RemoteFilePreview(file: file, content: content)
        } catch is CancellationError {
            return
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

    func mutate(_ mutation: SFTPRemoteMutation) async {
        guard !isMutating else {
            errorMessage = "另一个远程操作正在进行。"
            return
        }
        isMutating = true
        defer { isMutating = false }

        do {
            try await applyMutation(mutation)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveFile(_ file: RemoteFilePreview, content: String) async -> Bool {
        guard !isMutating else {
            errorMessage = "另一个远程操作正在进行。"
            return false
        }
        isMutating = true
        defer { isMutating = false }

        do {
            try await applyMutation(.writeFile(path: file.file.path, content: content))
            preview = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

struct RemoteFilePreview: Identifiable {
    let file: RemoteFile
    let content: String

    var id: String { file.id }
}

private enum SFTPNameOperation {
    case createDirectory
    case createFile
    case rename(RemoteFile)

    var title: LocalizedStringKey {
        switch self {
        case .createDirectory: "新建文件夹"
        case .createFile: "新建文件"
        case .rename: "重命名"
        }
    }

    var initialName: String {
        if case .rename(let file) = self {
            return file.name
        }
        return ""
    }
}

private struct SFTPNameInput: Identifiable {
    let id = UUID()
    let operation: SFTPNameOperation
}

private enum SFTPFileSortOrder: String, CaseIterable, Identifiable {
    case name
    case size
    case modified

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .name: "名称"
        case .size: "大小"
        case .modified: "修改时间"
        }
    }
}

struct SFTPView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: SFTPViewModel
    @ObservedObject var transferViewModel: SFTPTransferViewModel
    let onDownload: (RemoteFile) -> Void
    let onUpload: (URL, String) -> Void
    let onShowLocalFile: (URL) -> Void
    @State private var showingMissions = false
    @State private var showingFileImporter = false
    @State private var nameInput: SFTPNameInput?
    @State private var fileToDelete: RemoteFile?
    @State private var fileForPermissions: RemoteFile?
    @State private var searchText = ""
    @State private var sortOrder: SFTPFileSortOrder = .name
    @State private var sortAscending = true
    @State private var showingPathInput = false

    init(
        listDirectory: @escaping (String) async throws -> [RemoteFile],
        readFile: @escaping (String) async throws -> String,
        applyMutation: @escaping (SFTPRemoteMutation) async throws -> Void,
        initialPath: @escaping () async throws -> String,
        transferViewModel: SFTPTransferViewModel,
        onDownload: @escaping (RemoteFile) -> Void,
        onUpload: @escaping (URL, String) -> Void,
        onShowLocalFile: @escaping (URL) -> Void
    ) {
        self.transferViewModel = transferViewModel
        self.onDownload = onDownload
        self.onUpload = onUpload
        self.onShowLocalFile = onShowLocalFile
        _viewModel = StateObject(
            wrappedValue: SFTPViewModel(
                listDirectory: listDirectory,
                readFile: readFile,
                applyMutation: applyMutation,
                initialPath: initialPath
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
                    ProgressView("正在加载目录...")
                } else if viewModel.files.isEmpty {
                    ContentUnavailableView(
                        "目录为空",
                        systemImage: "folder",
                        description: Text("这里没有可显示的文件。")
                    )
                } else if filteredFiles.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    ForEach(filteredFiles) { file in
                        HStack(spacing: DesignTokens.spaceS) {
                            Button {
                                Task { await viewModel.open(file) }
                            } label: {
                                fileRow(file)
                            }
                            .buttonStyle(.plain)

                            if !file.isDirectory {
                                Button {
                                    onDownload(file)
                                } label: {
                                    Image(systemName: "arrow.down.circle")
                                        .font(.title3)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("下载 \(file.name)")
                            }
                        }
                        .disabled(viewModel.isMutating)
                        .contextMenu {
                            Button("重命名", systemImage: "pencil") {
                                nameInput = SFTPNameInput(operation: .rename(file))
                            }
                            .disabled(viewModel.isMutating)
                            if !file.isDirectory {
                                Button("下载", systemImage: "arrow.down.circle") {
                                    onDownload(file)
                                }
                                .disabled(viewModel.isMutating)
                            }
                            Button("权限", systemImage: "lock") {
                                fileForPermissions = file
                            }
                            .disabled(viewModel.isMutating)
                            Button("删除", systemImage: "trash", role: .destructive) {
                                fileToDelete = file
                            }
                            .disabled(viewModel.isMutating)
                        }
                    }
                }
            }
            .navigationTitle(viewModel.path == "/" ? "SFTP" : viewModel.path)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await viewModel.loadInitial() }
                    } label: {
                        Image(systemName: "house")
                    }
                    .accessibilityLabel("主目录")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingPathInput = true
                    } label: {
                        Image(systemName: "location")
                    }
                    .accessibilityLabel("跳转路径")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(SFTPFileSortOrder.allCases) { order in
                            Button {
                                if sortOrder == order {
                                    sortAscending.toggle()
                                } else {
                                    sortOrder = order
                                    sortAscending = true
                                }
                            } label: {
                                if sortOrder == order {
                                    Label(order.title, systemImage: "checkmark")
                                } else {
                                    Text(order.title)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .accessibilityLabel("文件排序")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingFileImporter = true
                    } label: {
                        Image(systemName: "arrow.up.doc")
                    }
                    .accessibilityLabel("上传文件")
                    .disabled(viewModel.isMutating)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("新建文件夹", systemImage: "folder.badge.plus") {
                            nameInput = SFTPNameInput(operation: .createDirectory)
                        }
                        Button("新建文件", systemImage: "doc.badge.plus") {
                            nameInput = SFTPNameInput(operation: .createFile)
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("创建远程项目")
                    .disabled(viewModel.isMutating)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingMissions = true
                    } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .accessibilityLabel("SFTP 任务")
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
                    .accessibilityLabel("刷新目录")
                }
            }
            .task {
                await viewModel.loadInitial()
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
            .alert(
                "SFTP 错误",
                isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { isPresented in
                        if !isPresented { viewModel.errorMessage = nil }
                    }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "未知 SFTP 错误")
            }
            .sheet(item: $viewModel.preview) { preview in
                RemoteFilePreviewView(preview: preview) { content in
                    await viewModel.saveFile(preview, content: content)
                }
            }
            .sheet(item: $fileForPermissions) { file in
                SFTPPermissionsInputView(file: file) { permissions in
                    fileForPermissions = nil
                    Task {
                        await viewModel.mutate(
                            .chmod(path: file.path, permissions: permissions)
                        )
                    }
                }
            }
            .sheet(isPresented: $showingMissions) {
                SFTPMissionsView(
                    viewModel: transferViewModel,
                    onShowInFiles: onShowLocalFile
                )
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    onUpload(url, viewModel.path)
                }
            }
            .sheet(item: $nameInput) { input in
                SFTPNameInputView(input: input) { name in
                    nameInput = nil
                    guard let mutation = makeMutation(input.operation, name: name) else {
                        viewModel.errorMessage = "名称不能为空且不能包含斜杠。"
                        return
                    }
                    Task { await viewModel.mutate(mutation) }
                }
            }
            .sheet(isPresented: $showingPathInput) {
                SFTPPathInputView(path: viewModel.path) { path in
                    showingPathInput = false
                    Task { await viewModel.goTo(path: path) }
                }
            }
            .confirmationDialog(
                "删除远程项目？",
                isPresented: Binding(
                    get: { fileToDelete != nil },
                    set: { isPresented in
                        if !isPresented { fileToDelete = nil }
                    }
                )
            ) {
                Button("删除", role: .destructive) {
                    guard let file = fileToDelete else { return }
                    fileToDelete = nil
                    Task {
                        await viewModel.mutate(
                            .remove(
                                path: file.path,
                                isDirectory: file.isDirectory,
                                recursive: file.isDirectory
                            )
                        )
                    }
                }
                Button("取消", role: .cancel) {
                    fileToDelete = nil
                }
            } message: {
                Text(fileToDelete?.isDirectory == true
                    ? "此目录及其所有内容将被删除。"
                    : "此远程文件将被删除。")
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
                    if let permissions = file.permissions {
                        Text(permissionText(permissions))
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

    private var filteredFiles: [RemoteFile] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = query.isEmpty
            ? viewModel.files
            : viewModel.files.filter { $0.name.localizedCaseInsensitiveContains(query) }
        let sorted = matching.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            let result: ComparisonResult
            switch sortOrder {
            case .name:
                result = lhs.name.localizedStandardCompare(rhs.name)
            case .size:
                result = compare(lhs.size ?? 0, rhs.size ?? 0)
            case .modified:
                result = compare(lhs.modifiedAt ?? .distantPast, rhs.modifiedAt ?? .distantPast)
            }
            return sortAscending
                ? result == .orderedAscending
                : result == .orderedDescending
        }
        return sorted
    }

    private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    private func permissionText(_ permissions: UInt32) -> String {
        let value = String(permissions & 0o7777, radix: 8)
        return String(repeating: "0", count: max(0, 4 - value.count)) + value
    }

    private func makeMutation(
        _ operation: SFTPNameOperation,
        name: String
    ) -> SFTPRemoteMutation? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            return nil
        }
        let path = viewModel.path == "/"
            ? "/\(name)"
            : "\(viewModel.path)/\(name)"

        switch operation {
        case .createDirectory:
            return .createDirectory(path: path)
        case .createFile:
            return .createFile(path: path)
        case .rename(let file):
            return .rename(oldPath: file.path, newPath: path)
        }
    }
}

private struct SFTPNameInputView: View {
    @Environment(\.dismiss) private var dismiss
    let input: SFTPNameInput
    let onSubmit: (String) -> Void
    @State private var name: String

    init(input: SFTPNameInput, onSubmit: @escaping (String) -> Void) {
        self.input = input
        self.onSubmit = onSubmit
        _name = State(initialValue: input.operation.initialName)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("名称", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .navigationTitle(input.operation.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSubmit(name)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct SFTPPathInputView: View {
    @Environment(\.dismiss) private var dismiss
    let path: String
    let onSubmit: (String) -> Void
    @State private var value: String

    init(path: String, onSubmit: @escaping (String) -> Void) {
        self.path = path
        self.onSubmit = onSubmit
        _value = State(initialValue: path)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("路径", text: $value)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .navigationTitle("跳转路径")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("跳转") {
                        onSubmit(value)
                        dismiss()
                    }
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct SFTPPermissionsInputView: View {
    @Environment(\.dismiss) private var dismiss
    let file: RemoteFile
    let onSubmit: (UInt32) -> Void
    @State private var value: String
    @State private var errorMessage: String?

    init(file: RemoteFile, onSubmit: @escaping (UInt32) -> Void) {
        self.file = file
        self.onSubmit = onSubmit
        let permissions = file.permissions.map { String($0 & 0o7777, radix: 8) } ?? "644"
        _value = State(
            initialValue: String(repeating: "0", count: max(0, 4 - permissions.count)) + permissions
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("八进制权限", text: $value)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("请使用 0644 或 0755 之类的值。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("权限")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { submit() }
                }
            }
            .alert(
                "权限无效",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "请输入八进制权限值。")
            }
        }
    }

    private func submit() {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.allSatisfy({ "01234567".contains($0) }),
              let permissions = UInt32(normalized, radix: 8),
              permissions <= 0o7777 else {
            errorMessage = "请输入 0000 到 7777 之间的八进制值。"
            return
        }
        onSubmit(permissions)
        dismiss()
    }
}

private struct RemoteFilePreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let preview: RemoteFilePreview
    let onSave: (String) async -> Bool
    @State private var content: String
    @State private var isSaving = false

    init(preview: RemoteFilePreview, onSave: @escaping (String) async -> Bool) {
        self.preview = preview
        self.onSave = onSave
        _content = State(initialValue: preview.content)
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $content)
                .font(.system(.footnote, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(DesignTokens.spaceS)
            .navigationTitle(preview.file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            isSaving = true
                            if await onSave(content) {
                                dismiss()
                            }
                            isSaving = false
                        }
                    }
                    .disabled(isSaving)
                }
            }
            .overlay {
                if isSaving { ProgressView() }
            }
        }
    }
}
