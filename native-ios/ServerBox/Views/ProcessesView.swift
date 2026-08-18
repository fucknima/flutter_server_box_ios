import Foundation
import SwiftUI
import UIKit

enum ProcessSortMode: String, CaseIterable {
    case cpu
    case memory
    case read
    case write
    case name

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "内存"
        case .read: return "IO 读"
        case .write: return "IO 写"
        case .name: return "命令"
        }
    }

    var defaultAscending: Bool {
        switch self {
        case .name: return true
        default: return false
        }
    }
}

@MainActor
final class ProcessesViewModel: ObservableObject {
    @Published private(set) var processes: [RemoteProcess] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var processToTerminate: RemoteProcess?
    @Published var processToInspect: RemoteProcess?
    @Published var searchText = ""
    @Published private(set) var sortMode: ProcessSortMode = .cpu
    @Published private(set) var sortAscending = false

    private let listProcesses: () async throws -> [RemoteProcess]
    private let terminateProcess: (RemoteProcess, ProcessSignal) async throws -> Void

    init(
        listProcesses: @escaping () async throws -> [RemoteProcess],
        terminateProcess: @escaping (RemoteProcess, ProcessSignal) async throws -> Void
    ) {
        self.listProcesses = listProcesses
        self.terminateProcess = terminateProcess
    }

    var displayedProcesses: [RemoteProcess] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty
            ? processes
            : processes.filter { $0.command.localizedCaseInsensitiveContains(query) }
        var result = filtered
        result.sort { compare($0, $1) == .orderedAscending }
        return result
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

    func toggleSort(_ mode: ProcessSortMode) {
        if sortMode == mode {
            sortAscending.toggle()
        } else {
            sortMode = mode
            sortAscending = mode.defaultAscending
        }
    }

    private func compare(_ a: RemoteProcess, _ b: RemoteProcess) -> ComparisonResult {
        let primary: ComparisonResult
        switch sortMode {
        case .cpu:
            primary = compareDirection(a.cpuPercent, b.cpuPercent)
        case .memory:
            primary = compareDirection(a.memoryPercent, b.memoryPercent)
        case .read:
            primary = compareIOSample(a, b) { $0.readSpeed }
        case .write:
            primary = compareIOSample(a, b) { $0.writeSpeed }
        case .name:
            primary = a.command.localizedCaseInsensitiveCompare(b.command)
        }
        if primary != .orderedSame { return primary }
        if a.pid == b.pid { return .orderedSame }
        return a.pid < b.pid ? .orderedAscending : .orderedDescending
    }

    private func compareDirection(_ av: Double, _ bv: Double) -> ComparisonResult {
        if av == bv { return .orderedSame }
        if sortAscending {
            return av < bv ? .orderedAscending : .orderedDescending
        }
        return av > bv ? .orderedAscending : .orderedDescending
    }

    private func compareIOSample(
        _ a: RemoteProcess,
        _ b: RemoteProcess,
        speed: (RemoteProcess) -> Double
    ) -> ComparisonResult {
        let aHasSample = a.readBytes >= 0 || a.writeBytes >= 0
        let bHasSample = b.readBytes >= 0 || b.writeBytes >= 0
        if aHasSample != bHasSample {
            return aHasSample ? .orderedAscending : .orderedDescending
        }
        if !aHasSample { return .orderedSame }
        return compareDirection(speed(a), speed(b))
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
            VStack(spacing: 0) {
                HStack {
                    Text("共 \(viewModel.displayedProcesses.count) 个进程")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                }
                .padding(.horizontal, DesignTokens.spaceM)
                .padding(.vertical, 6)

                List {
                    ForEach(viewModel.displayedProcesses) { process in
                        processRow(process)
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    await viewModel.load()
                }
                .overlay {
                    if viewModel.isLoading && viewModel.displayedProcesses.isEmpty {
                        ProgressView("正在加载进程...")
                    } else if !viewModel.isLoading && viewModel.processes.isEmpty {
                        ContentUnavailableView(
                            viewModel.errorMessage ?? "没有进程",
                            systemImage: viewModel.errorMessage == nil ? "cpu" : "exclamationmark.triangle",
                            description: viewModel.errorMessage == nil
                                ? Text("服务器没有返回进程记录。")
                                : Text("刷新重试，或检查服务器连接。")
                        )
                    } else if !viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              viewModel.displayedProcesses.isEmpty {
                        ContentUnavailableView(
                            "没有匹配的进程",
                            systemImage: "magnifyingglass",
                            description: Text("没有命令包含当前搜索关键字。")
                        )
                    }
                }
            }
            .navigationTitle("进程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: DesignTokens.spaceM) {
                        Menu {
                            ForEach(ProcessSortMode.allCases, id: \.self) { mode in
                                Button {
                                    viewModel.toggleSort(mode)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(
                                            systemName: viewModel.sortMode == mode
                                                ? "checkmark.circle.fill"
                                                : "circle"
                                        )
                                        Text(mode.title)
                                        if viewModel.sortMode == mode {
                                            Image(
                                                systemName: viewModel.sortAscending
                                                    ? "arrow.up"
                                                    : "arrow.down"
                                            )
                                        }
                                    }
                                }
                            }
                        } label: {
                            Label(viewModel.sortMode.title, systemImage: "arrow.up.arrow.down")
                        }
                        .accessibilityLabel("排序")
                        .accessibilityValue(
                            "\(viewModel.sortMode.title)，\(viewModel.sortAscending ? "升序" : "降序")"
                        )

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
                        .accessibilityLabel("刷新进程")
                    }
                }
            }
            .task {
                await viewModel.load()
            }
            .searchable(text: $viewModel.searchText, prompt: "搜索进程")
            .confirmationDialog(
                "终止进程？",
                isPresented: Binding(
                    get: { viewModel.processToTerminate != nil },
                    set: { isPresented in
                        if !isPresented { viewModel.processToTerminate = nil }
                    }
                )
            ) {
                Button("结束进程", role: .destructive) {
                    Task { await viewModel.terminate(signal: .terminate) }
                }
                Button("强制结束", role: .destructive) {
                    Task { await viewModel.terminate(signal: .kill) }
                }
                Button("取消", role: .cancel) {
                    viewModel.processToTerminate = nil
                }
            } message: {
                if let process = viewModel.processToTerminate {
                    Text("PID \(process.pid): \(process.command)")
                }
            }
            .sheet(item: $viewModel.processToInspect) { process in
                ProcessDetailsSheet(process: process)
                    .presentationDetents([.medium])
            }
            .alert(
                "进程错误",
                isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { isPresented in
                        if !isPresented { viewModel.errorMessage = nil }
                    }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "未知进程错误")
            }
        }
        .tint(DesignTokens.accent)
    }

    private func processRow(_ process: RemoteProcess) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.spaceS) {
            Button {
                viewModel.processToInspect = process
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.spaceM) {
                        commandText(process.command)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text("#\(process.pid)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    FlowLayout(spacing: 12) {
                        metadataTexts(process)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .multilineTextAlignment(.leading)

            Button {
                viewModel.processToTerminate = process
            } label: {
                Image(systemName: "stop.circle")
                    .font(.title3)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.isLoading)
            .accessibilityLabel("结束进程 \(process.pid)")
        }
    }

    private func commandText(_ command: String) -> some View {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.split(
            whereSeparator: { $0 == " " || $0 == "\t" }
        ).first else {
            return Text("—")
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        let name = String(first)
        let args = trimmed.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
        return Text(name)
            .font(.system(.subheadline, design: .monospaced, weight: .medium))
            + Text(args.isEmpty ? "" : " \(args)")
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func metadataTexts(_ process: RemoteProcess) -> some View {
        if !process.user.isEmpty {
            Text(process.user)
        }
        Text(String(format: "CPU %.1f%%", process.cpuPercent))
        Text(String(format: "内存 %.1f%%", process.memoryPercent))
        if let rss = Self.formattedRss(process) {
            Text("RSS \(rss)")
        }
        if process.readBytes >= 0 || process.writeBytes >= 0 {
            Text("读 \(Self.formatSpeed(process.readSpeed))")
            Text("写 \(Self.formatSpeed(process.writeSpeed))")
        }
    }

    fileprivate static func formatBytes(_ value: Double) -> String {
        let units = ["B", "K", "M", "G", "T", "P"]
        var amount = value
        var unitIndex = 0
        while amount >= 1024, unitIndex < units.count - 1 {
            amount /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(Int(amount))\(units[unitIndex])"
        }
        return String(format: "%.1f%@", amount, units[unitIndex])
    }

    fileprivate static func formatSpeed(_ value: Double) -> String {
        formatBytes(value) + "/s"
    }

    fileprivate static func formattedRss(_ process: RemoteProcess) -> String? {
        guard let rssKb = process.rssKb else { return nil }
        return formatBytes(rssKb * 1024)
    }

    fileprivate static func formattedVsz(_ process: RemoteProcess) -> String? {
        guard !process.vsz.isEmpty, process.vsz != "-" else { return nil }
        guard let kb = Double(process.vsz.replacingOccurrences(of: ",", with: ".")) else {
            return nil
        }
        return formatBytes(kb * 1024)
    }
}

private struct ProcessDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let process: RemoteProcess

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.spaceS) {
                    detailRow("PID", "\(process.pid)")
                    if !process.user.isEmpty {
                        detailRow("用户", process.user)
                    }
                    detailRow("CPU", String(format: "%.1f%%", process.cpuPercent))
                    detailRow("内存", String(format: "%.1f%%", process.memoryPercent))
                    if let vsz = ProcessesView.formattedVsz(process) {
                        detailRow("VSZ", vsz)
                    }
                    if let rss = ProcessesView.formattedRss(process) {
                        detailRow("RSS", rss)
                    }
                    if process.readBytes >= 0 || process.writeBytes >= 0 {
                        detailRow("读取", ProcessesView.formatSpeed(process.readSpeed))
                        detailRow("写入", ProcessesView.formatSpeed(process.writeSpeed))
                    }
                    if !process.tty.isEmpty {
                        detailRow("TTY", process.tty)
                    }
                    if !process.stat.isEmpty {
                        detailRow("STAT", process.stat)
                    }
                    if !process.startId.isEmpty {
                        detailRow("START", process.startId)
                    }
                    if !process.time.isEmpty {
                        detailRow("TIME", process.time)
                    }
                    Divider()
                    Text(process.command.isEmpty ? "—" : process.command)
                        .font(.system(.subheadline, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding(DesignTokens.spaceM)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("进程 #\(process.pid)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("复制") {
                        UIPasteboard.general.string = process.command
                    }
                }
            }
        }
        .tint(DesignTokens.accent)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 12

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
