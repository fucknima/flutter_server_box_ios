import Network
import SwiftUI

struct DiscoveredSSHServer: Identifiable, Hashable, Sendable {
    let host: String
    let port: Int

    var id: String { "\(host):\(port)" }
}

@MainActor
final class ServerDiscoveryViewModel: ObservableObject {
    @Published private(set) var discovered: [DiscoveredSSHServer] = []
    @Published private(set) var isScanning = false
    @Published var errorMessage: String?
    private var scanTask: Task<Void, Never>?

    deinit {
        scanTask?.cancel()
    }

    func scan(prefix: String, start: Int, end: Int, port: Int) {
        scanTask?.cancel()
        discovered = []
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
        scanTask = Task { [weak self] in
            let hosts = (start...end).map { "\(normalizedPrefix).\($0)" }
            var found: [DiscoveredSSHServer] = []

            await withTaskGroup(of: DiscoveredSSHServer?.self) { group in
                for host in hosts {
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        guard await Self.isReachable(host: host, port: port) else { return nil }
                        return DiscoveredSSHServer(host: host, port: port)
                    }
                }
                for await result in group {
                    if let result { found.append(result) }
                }
            }

            guard !Task.isCancelled else { return }
            found.sort { $0.host.localizedStandardCompare($1.host) == .orderedAscending }
            self?.discovered = found
            self?.isScanning = false
        }
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    private static func isReachable(host: String, port: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
                continuation.resume(returning: false)
                return
            }

            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: nwPort,
                using: .tcp
            )
            let lock = NSLock()
            var completed = false

            func finish(_ result: Bool) {
                lock.lock()
                defer { lock.unlock() }
                guard !completed else { return }
                completed = true
                connection.cancel()
                continuation.resume(returning: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue.global(qos: .userInitiated))
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.5) {
                finish(false)
            }
        }
    }
}

struct ServerDiscoveryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var serverViewModel: ServerListViewModel
    @StateObject private var viewModel = ServerDiscoveryViewModel()
    @State private var prefix = "192.168.1"
    @State private var startHost = "1"
    @State private var endHost = "254"
    @State private var port = "22"
    @State private var username = "root"
    @State private var editorServer: ServerConfiguration?

    var body: some View {
        NavigationStack {
            Form {
                Section("扫描") {
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
                    TextField("SSH 端口", text: $port)
                        .keyboardType(.numberPad)
                    TextField("用户名", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        startScan()
                    } label: {
                        if viewModel.isScanning {
                            ProgressView("扫描中...")
                        } else {
                            Label("开始扫描", systemImage: "dot.radiowaves.left.and.right")
                        }
                    }
                    .disabled(viewModel.isScanning)
                }

                Section("发现的 SSH 主机") {
                    if viewModel.isScanning && viewModel.discovered.isEmpty {
                        ProgressView("正在检查主机...")
                    } else if viewModel.discovered.isEmpty {
                        Text("暂未发现可连接的 SSH 主机。")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.discovered) { server in
                            Button {
                                editorServer = ServerConfiguration(
                                    name: server.host,
                                    host: server.host,
                                    port: server.port,
                                    username: username
                                )
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(server.host)
                                        Text("SSH 端口 \(server.port)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "server.rack")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("服务器发现")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        viewModel.cancel()
                        dismiss()
                    }
                }
            }
            .sheet(item: $editorServer) { server in
                ServerEditorView(
                    server: server,
                    availableServers: serverViewModel.servers
                ) { draft in
                    try await serverViewModel.save(draft)
                }
            }
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
        .tint(DesignTokens.accent)
    }

    private func startScan() {
        viewModel.scan(
            prefix: prefix,
            start: Int(startHost) ?? -1,
            end: Int(endHost) ?? -1,
            port: Int(port) ?? -1
        )
    }
}
