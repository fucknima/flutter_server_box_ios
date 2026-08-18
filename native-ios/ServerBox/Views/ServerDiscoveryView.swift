import SwiftUI

@MainActor
final class ServerDiscoveryViewModel: ObservableObject {
    @Published private(set) var discovered: [SSHDiscoveredHost] = []
    @Published private(set) var subnets: [IPSubnet] = []
    @Published private(set) var lastReport: SSHDiscoveryReport?
    @Published private(set) var isScanning = false
    @Published var errorMessage: String?
    private var scanTask: Task<Void, Never>?

    deinit {
        scanTask?.cancel()
    }

    func loadSubnets() {
        guard subnets.isEmpty else { return }
        subnets = SSHDiscoveryService.localSubnets()
    }

    func scanManual(prefix: String, start: Int, end: Int, port: Int, config: SSHDiscoveryConfig) {
        scanTask?.cancel()
        discovered = []
        lastReport = nil
        errorMessage = nil

        let normalizedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrefix.isEmpty,
              (0...255).contains(start),
              (0...255).contains(end),
              start <= end,
              (1...65_535).contains(port) else {
            errorMessage = "请输入有效的 IPv4 前缀、主机范围和端口。"
            return
        }

        isScanning = true
        let startedAt = Date()
        scanTask = Task { [weak self] in
            let hosts = (start...end).map { "\(normalizedPrefix).\($0)" }
            let found = await SSHDiscoveryService.scanHosts(
                hosts,
                port: port,
                timeoutMs: config.timeoutMs,
                maxConcurrency: config.maxConcurrency
            )
            guard !Task.isCancelled else { return }
            let sorted = found.sorted {
                $0.host.localizedStandardCompare($1.host) == .orderedAscending
            }
            let durationMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
            self?.discovered = sorted
            self?.lastReport = SSHDiscoveryReport(
                generatedAt: Date(),
                durationMs: durationMs,
                items: sorted
            )
            self?.isScanning = false
        }
    }

    func scanAuto(port: Int, config: SSHDiscoveryConfig) {
        scanTask?.cancel()
        discovered = []
        lastReport = nil
        errorMessage = nil

        guard (1...65_535).contains(port) else {
            errorMessage = "请输入有效的 SSH 端口。"
            return
        }

        isScanning = true
        let startedAt = Date()
        scanTask = Task { [weak self] in
            let subnets = SSHDiscoveryService.localSubnets()
            self?.subnets = subnets

            var candidates = Set<String>()
            for subnet in subnets {
                for host in subnet.enumerateHosts(limit: SSHDiscoveryService.hostEnumerationLimit) {
                    candidates.insert(host)
                }
            }

            let mdnsHosts = config.enableMdns
                ? await SSHDiscoveryService.mdnsSSHHosts()
                : []
            let scanned = await SSHDiscoveryService.scanHosts(
                Array(candidates),
                port: port,
                timeoutMs: config.timeoutMs,
                maxConcurrency: config.maxConcurrency
            )

            var results = scanned
            var seen = Set(results.map(\.id))
            for host in mdnsHosts where !seen.contains(host.id) {
                results.append(host)
                seen.insert(host.id)
            }

            guard !Task.isCancelled else { return }
            results.sort {
                $0.host.localizedStandardCompare($1.host) == .orderedAscending
            }
            let durationMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
            self?.discovered = results
            self?.lastReport = SSHDiscoveryReport(
                generatedAt: Date(),
                durationMs: durationMs,
                items: results
            )
            self?.isScanning = false
        }
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }
}

struct ServerDiscoveryView: View {
    enum ScanMode: String, CaseIterable, Identifiable {
        case manual = "手动范围"
        case auto = "自动发现"

        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var serverViewModel: ServerListViewModel
    var onAddServers: (([ServerConfiguration]) -> Void)? = nil

    @StateObject private var viewModel = ServerDiscoveryViewModel()
    @State private var scanMode: ScanMode = .manual
    @State private var prefix = "192.168.1"
    @State private var startHost = "1"
    @State private var endHost = "254"
    @State private var port = "22"
    @State private var username = "root"
    @State private var timeoutMsText = "700"
    @State private var maxConcurrencyText = "128"
    @State private var enableMdns = false
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var editorServer: ServerConfiguration?
    @State private var showSettings = false
    @State private var importMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                scanSection
                subnetSection
                summarySection
                resultsSection
            }
            .navigationTitle("服务器发现")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .sheet(item: $editorServer) { server in
                ServerEditorView(
                    server: server,
                    availableServers: serverViewModel.servers
                ) { draft in
                    try await serverViewModel.save(draft)
                }
            }
            .sheet(isPresented: $showSettings) { settingsSheet }
            .alert(
                "发现错误",
                isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { if !$0 { viewModel.errorMessage = nil } }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "未知发现错误")
            }
        }
        .alert(
            "批量导入",
            isPresented: Binding(
                get: { importMessage != nil },
                set: { if !$0 { importMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(importMessage ?? "批量导入完成。")
        }
        .tint(DesignTokens.accent)
    }

    private var scanSection: some View {
        Section {
            Picker("扫描方式", selection: $scanMode) {
                ForEach(ScanMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .onChange(of: scanMode) { _, newMode in
                if newMode == .auto {
                    viewModel.loadSubnets()
                }
            }
            if scanMode == .manual {
                TextField("IPv4 前缀", text: $prefix)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    TextField("起始", text: $startHost)
                        .keyboardType(.numberPad)
                    Text("-")
                    TextField("结束", text: $endHost)
                        .keyboardType(.numberPad)
                }
            }
            TextField("SSH 端口", text: $port)
                .keyboardType(.numberPad)
            TextField("用户名", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                startScan()
            } label: {
                if viewModel.isScanning {
                    ProgressView(scanMode == .auto ? "自动发现中..." : "扫描中...")
                } else {
                    Label("开始扫描", systemImage: "dot.radiowaves.left.and.right")
                }
            }
            .disabled(viewModel.isScanning)
        } header: {
            Text("扫描")
        } footer: {
            if scanMode == .auto {
                Text("自动发现将枚举本机子网内的主机，启用 mDNS 时同时查找局域网中广播的 Bonjour SSH 服务。")
            }
        }
    }

    @ViewBuilder
    private var subnetSection: some View {
        if scanMode == .auto {
            Section("本机子网") {
                if viewModel.subnets.isEmpty {
                    Text("未检测到可枚举的局域网子网。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.subnets, id: \.self) { subnet in
                        HStack {
                            Text(subnet.cidrDescription)
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Text("\(subnet.enumerateHosts(limit: SSHDiscoveryService.hostEnumerationLimit).count) 台")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        if let report = viewModel.lastReport {
            Section("扫描摘要") {
                LabeledContent("发现数量", value: "\(report.count) 台")
                LabeledContent("耗时", value: "\(report.durationMs) ms")
                LabeledContent("完成时间", value: Self.formatDate(report.generatedAt))
            }
        }
    }

    private var resultsSection: some View {
        Section("发现的 SSH 主机") {
            if viewModel.isScanning && viewModel.discovered.isEmpty {
                ProgressView("正在检查主机...")
            } else if viewModel.discovered.isEmpty {
                Text("暂未发现可连接的 SSH 主机。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.discovered) { server in
                    Button {
                        toggleSelection(of: server)
                    } label: {
                        HStack {
                            if isSelecting {
                                Image(systemName: selectedIDs.contains(server.id)
                                    ? "checkmark.circle.fill"
                                    : "circle")
                                    .foregroundStyle(selectedIDs.contains(server.id)
                                        ? Color.green
                                        : Color.secondary)
                            } else {
                                Image(systemName: "server.rack")
                                    .foregroundStyle(.green)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(server.host)
                                if let banner = server.banner {
                                    Text(banner)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                } else {
                                    Text("SSH 端口 \(server.port)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("关闭") {
                viewModel.cancel()
                dismiss()
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if !viewModel.isScanning {
                if isSelecting {
                    Button("取消") {
                        exitSelectionMode()
                    }
                } else {
                    HStack(spacing: 16) {
                        if !viewModel.discovered.isEmpty {
                            Button("多选") {
                                isSelecting = true
                            }
                        }
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
            }
        }
        ToolbarItem(placement: .bottomBar) {
            if isSelecting {
                HStack {
                    Button("全选") {
                        if selectedIDs.count == viewModel.discovered.count {
                            selectedIDs.removeAll()
                        } else {
                            selectedIDs = Set(viewModel.discovered.map(\.id))
                        }
                    }
                    Spacer()
                    Button("导入 (\(selectedIDs.count))") {
                        importSelectedServers()
                    }
                    .disabled(selectedIDs.isEmpty)
                }
            }
        }
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("超时（毫秒）", text: $timeoutMsText)
                        .keyboardType(.numberPad)
                    TextField("并发数", text: $maxConcurrencyText)
                        .keyboardType(.numberPad)
                    Toggle("启用 mDNS 发现", isOn: $enableMdns)
                } header: {
                    Text("扫描设置")
                } footer: {
                    Text("mDNS 用于发现局域网中通过 Bonjour 广播的 SSH 服务（_ssh._tcp）。")
                }
            }
            .navigationTitle("扫描设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        showSettings = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var trimmedUsername: String {
        let value = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "root" : value
    }

    private func startScan() {
        exitSelectionMode()
        let config = SSHDiscoveryConfig(
            timeoutMs: Int(timeoutMsText) ?? SSHDiscoveryConfig.default.timeoutMs,
            maxConcurrency: Int(maxConcurrencyText) ?? SSHDiscoveryConfig.default.maxConcurrency,
            enableMdns: enableMdns
        )
        if scanMode == .auto {
            viewModel.scanAuto(port: Int(port) ?? -1, config: config)
        } else {
            viewModel.scanManual(
                prefix: prefix,
                start: Int(startHost) ?? -1,
                end: Int(endHost) ?? -1,
                port: Int(port) ?? -1,
                config: config
            )
        }
    }

    private func toggleSelection(of server: SSHDiscoveredHost) {
        if isSelecting {
            if selectedIDs.contains(server.id) {
                selectedIDs.remove(server.id)
            } else {
                selectedIDs.insert(server.id)
            }
        } else {
            editorServer = ServerConfiguration(
                name: server.host,
                host: server.host,
                port: server.port,
                username: trimmedUsername
            )
        }
    }

    private func importSelectedServers() {
        let selected = viewModel.discovered.filter { selectedIDs.contains($0.id) }
        guard !selected.isEmpty else { return }

        let user = trimmedUsername
        var usedNames = Set(serverViewModel.servers.map(\.name))
        var addedConnectionKeys = Set<String>()
        var toAdd: [ServerConfiguration] = []

        for server in selected {
            let configuration = ServerConfiguration(
                name: uniqueName(base: server.host, used: &usedNames),
                host: server.host,
                port: server.port,
                username: user
            )
            let connectionKey = "\(configuration.host):\(configuration.port):\(user)"
            let alreadyExists = serverViewModel.servers.contains {
                $0.isSameConnection(as: configuration)
            }
            guard !alreadyExists, !addedConnectionKeys.contains(connectionKey) else {
                continue
            }
            addedConnectionKeys.insert(connectionKey)
            toAdd.append(configuration)
        }

        if let onAddServers {
            onAddServers(toAdd)
        } else {
            for configuration in toAdd {
                serverViewModel.upsert(configuration)
            }
        }

        importMessage = toAdd.isEmpty
            ? "所选服务器均已存在，未导入新服务器。"
            : "已导入 \(toAdd.count) 台服务器。"
        exitSelectionMode()
    }

    private func uniqueName(base: String, used: inout Set<String>) -> String {
        var candidate = base
        var suffix = 1
        while used.contains(candidate) {
            suffix += 1
            candidate = "\(base) (\(suffix))"
        }
        used.insert(candidate)
        return candidate
    }

    private func exitSelectionMode() {
        isSelecting = false
        selectedIDs.removeAll()
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
