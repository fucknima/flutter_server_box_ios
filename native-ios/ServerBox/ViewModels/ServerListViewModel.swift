import Combine
import Foundation

enum SSHConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

@MainActor
final class ServerListViewModel: ObservableObject {
    @Published private(set) var servers: [ServerConfiguration] = []
    @Published private(set) var states: [UUID: ServerStatusState] = [:]
    @Published private(set) var connectionStates: [UUID: SSHConnectionState] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published var storageError: String?

    private let store: ServerStore
    private let api: any MonitorAPIProtocol
    private let credentialStore: SSHCredentialStore
    private let sshStatusService: SSHStatusService
    private let connectionStatsStore: ConnectionStatsStore
    private var didLoad = false
    private var loadInProgress = false
    private var refreshGeneration = 0
    private var disconnectTask: Task<Void, Never>?
    private var connectionAttempts: [UUID: UUID] = [:]
    private var activeConnectionTokens: [UUID: UUID] = [:]
    private var persistTask: Task<Void, Error>?

    deinit {
        disconnectTask?.cancel()
        persistTask?.cancel()
    }

    init(
        store: ServerStore = .live,
        api: any MonitorAPIProtocol = MonitorAPI(),
        credentialStore: SSHCredentialStore = SSHCredentialStore(),
        sshStatusService: SSHStatusService = .live,
        connectionStatsStore: ConnectionStatsStore = .live
    ) {
        self.store = store
        self.api = api
        self.credentialStore = credentialStore
        self.sshStatusService = sshStatusService
        self.connectionStatsStore = connectionStatsStore
    }

    func start() async {
        await loadIfNeeded()

        if disconnectTask == nil {
            let events = await SSHConnectionService.live.unexpectedDisconnects()
            disconnectTask = Task { @MainActor [weak self] in
                for await event in events {
                    guard !Task.isCancelled else { return }
                    self?.handleUnexpectedDisconnect(event: event)
                }
            }
        }

        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await refreshAll()
        }
    }

    func loadIfNeeded() async {
        guard !didLoad, !loadInProgress else { return }
        loadInProgress = true
        isLoading = true
        defer {
            loadInProgress = false
            isLoading = false
        }

        do {
            servers = try await store.load().sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            didLoad = true
            states = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, .idle) })
            connectionStates = Dictionary(
                uniqueKeysWithValues: servers.map { ($0.id, .disconnected) }
            )
            for server in servers where server.autoConnect {
                await connect(server)
            }
            await refreshAll()
        } catch {
            storageError = error.localizedDescription
        }
    }

    func refreshAll() async {
        guard !servers.isEmpty else { return }

        refreshGeneration += 1
        let generation = refreshGeneration
        isRefreshing = true
        defer {
            if generation == refreshGeneration {
                isRefreshing = false
            }
        }

        let enabledServers = servers.filter(\.isEnabled)
        await withTaskGroup(of: Void.self) { group in
            for server in enabledServers {
                group.addTask { @MainActor [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    await self.refreshServer(server, generation: generation)
                }
            }
        }
    }

    private func refreshServer(
        _ server: ServerConfiguration,
        generation: Int
    ) async {
        guard generation == refreshGeneration, !Task.isCancelled else { return }

        guard let statusURL = server.statusURL else {
            guard connectionState(for: server) == .connected else {
                states[server.id] = .idle
                return
            }

            states[server.id] = .loading

            do {
                let status = try await sshStatusService.fetchStatus(for: server)
                guard generation == refreshGeneration else { return }
                states[server.id] = .loaded(status)
            } catch is CancellationError {
                return
            } catch {
                guard generation == refreshGeneration else { return }
                if let transportError = error as? SSHTransportError,
                   case .notConnected = transportError {
                    connectionStates[server.id] = .disconnected
                }
                states[server.id] = .failed(error.localizedDescription)
            }
            return
        }

        states[server.id] = .loading

        do {
            let monitorServer = MonitorServer(
                id: server.id,
                name: server.name,
                statusURL: statusURL,
                isEnabled: server.isEnabled,
                createdAt: server.createdAt
            )
            let status = try await api.fetchStatus(for: monitorServer)
            guard generation == refreshGeneration else { return }
            let merged = await mergeSSHStatus(status, for: server)
            guard generation == refreshGeneration else { return }
            states[server.id] = .loaded(merged)
        } catch is CancellationError {
            return
        } catch {
            guard generation == refreshGeneration else { return }
            states[server.id] = .failed(error.localizedDescription)
        }
    }

    private func mergeSSHStatus(
        _ status: ServerStatus,
        for server: ServerConfiguration
    ) async -> ServerStatus {
        guard connectionState(for: server) == .connected else { return status }
        guard let sshStatus = try? await sshStatusService.fetchStatus(for: server) else {
            return status
        }
        var merged = status
        merged.customCmds = sshStatus.customCmds
        if merged.dist.isEmpty {
            merged.dist = sshStatus.dist
        }
        if merged.cpu.isEmpty {
            merged.cpu = sshStatus.cpu
        }
        if merged.memory.isEmpty {
            merged.memory = sshStatus.memory
        }
        if merged.disk.isEmpty {
            merged.disk = sshStatus.disk
        }
        if merged.network.isEmpty {
            merged.network = sshStatus.network
        }
        return merged
    }

    func state(for server: ServerConfiguration) -> ServerStatusState {
        states[server.id] ?? .idle
    }

    func connectionState(for server: ServerConfiguration) -> SSHConnectionState {
        connectionStates[server.id] ?? .disconnected
    }

    private func handleUnexpectedDisconnect(event: SSHDisconnectEvent) {
        guard activeConnectionTokens[event.serverID] == event.connectionToken else { return }
        activeConnectionTokens.removeValue(forKey: event.serverID)
        guard connectionStates[event.serverID] == .connected
            || connectionStates[event.serverID] == .connecting else { return }
        let serverID = event.serverID
        guard let server = servers.first(where: { $0.id == serverID }) else { return }
        connectionAttempts.removeValue(forKey: serverID)
        connectionStates[serverID] = .disconnected
        if server.statusURL == nil {
            states[serverID] = .idle
        }
    }

    func save(_ draft: ServerEditorDraft) async throws {
        try draft.configuration.validate()

        let existingServer = servers.first { $0.id == draft.configuration.id }
        if let credential = draft.credential {
            try credentialStore.save(credential, for: draft.configuration.id)
        } else {
            let keepsExistingCredential = try loadCredential(for: draft.configuration) != nil
            guard keepsExistingCredential else {
                throw ServerConfigurationError.missingCredential
            }
        }

        var configuration = draft.configuration
        let connectionChanged = existingServer.map {
            !$0.isSameConnection(as: draft.configuration)
                || $0.knownHostKey != draft.configuration.knownHostKey
        } ?? true
        if let existingServer,
           !existingServer.isSameConnection(as: draft.configuration) {
            configuration.knownHostKey = nil
        }
        if existingServer != nil && (connectionChanged || draft.credential != nil) {
            await disconnect(configuration)
            states[configuration.id] = .idle
        }

        upsert(configuration)
    }

    func upsert(_ server: ServerConfiguration) {
        let previousServer = servers.first { $0.id == server.id }
        let connectionChanged = previousServer.map {
            !$0.isSameConnection(as: server) || $0.knownHostKey != server.knownHostKey
        } ?? true
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
        servers.sort {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        if connectionChanged {
            connectionAttempts.removeValue(forKey: server.id)
            activeConnectionTokens.removeValue(forKey: server.id)
            states[server.id] = .idle
            connectionStates[server.id] = .disconnected
        } else {
            states[server.id] = states[server.id] ?? .idle
            connectionStates[server.id] = connectionStates[server.id] ?? .disconnected
        }
        persist()
    }

    func importBackup(from url: URL) async throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let imported = try decoder.decode([ServerConfiguration].self, from: data)
        var importedIDs = Set<UUID>()
        for server in imported {
            try server.validate()
            guard importedIDs.insert(server.id).inserted else {
                throw ServerConfigurationError.duplicateBackupServer
            }
        }

        let originalServers = servers
        var mergedServers = servers
        var disconnectIDs = Set<UUID>()
        for server in imported {
            if let index = mergedServers.firstIndex(where: { $0.id == server.id }) {
                let existing = mergedServers[index]
                if !existing.isSameConnection(as: server) {
                    disconnectIDs.insert(server.id)
                } else if existing.knownHostKey != server.knownHostKey {
                    disconnectIDs.insert(server.id)
                }
                mergedServers[index] = server
            } else {
                mergedServers.append(server)
            }
        }
        mergedServers.sort {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let saveTask = enqueuePersistence(mergedServers)
        try await saveTask.value

        if servers == originalServers {
            servers = mergedServers
        } else {
            var reconciledServers = servers
            for server in imported {
                if let index = reconciledServers.firstIndex(where: { $0.id == server.id }) {
                    reconciledServers[index] = server
                } else {
                    reconciledServers.append(server)
                }
            }
            reconciledServers.sort {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            let reconciliationTask = enqueuePersistence(reconciledServers)
            try await reconciliationTask.value
            servers = reconciledServers
        }

        for server in imported {
            states[server.id] = .idle
            if disconnectIDs.contains(server.id) {
                await disconnect(server)
            } else {
                connectionStates[server.id] = connectionStates[server.id] ?? .disconnected
            }
        }
    }

    func importBulkServers(from url: URL) async throws -> Int {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        let imported = try JSONDecoder().decode([BulkImportServer].self, from: data)
        let privateKeys = try PrivateKeyStore.live.records()
        let existingNames = Set(servers.map(\.name))
        var usedNames = Set<String>()
        var added = 0

        for entry in imported {
            let trimmedName = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedHost = entry.ip.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty, !trimmedHost.isEmpty else { continue }

            let authentication: ServerAuthenticationReference
            let credential: ServerCredentialInput?
            if !entry.keyId.isEmpty,
               let record = privateKeys.first(where: { $0.name == entry.keyId }) {
                authentication = .privateKey(id: record.id)
                credential = nil
            } else if !entry.pwd.isEmpty {
                authentication = .password
                credential = .password(entry.pwd)
            } else {
                continue
            }

            let username = entry.user.trimmingCharacters(in: .whitespacesAndNewlines)
            let server = ServerConfiguration(
                name: resolveBulkName(
                    base: trimmedName,
                    existing: existingNames,
                    used: &usedNames
                ),
                host: trimmedHost,
                port: entry.port,
                username: username.isEmpty ? "root" : username,
                authentication: authentication,
                tags: entry.tags,
                alternateEndpoint: Self.parseAlternateURL(entry.alterUrl),
                autoConnect: entry.autoConnect
            )
            try server.validate()

            let isDuplicate = servers.contains { $0.isSameConnection(as: server) }
            guard !isDuplicate else { continue }

            if let credential {
                try credentialStore.save(credential, for: server.id)
            }
            upsert(server)
            added += 1
        }
        return added
    }

    private func resolveBulkName(
        base: String,
        existing: Set<String>,
        used: inout Set<String>
    ) -> String {
        var candidate = base
        var suffix = 1
        while existing.contains(candidate) || used.contains(candidate) {
            suffix += 1
            candidate = "\(base) (\(suffix))"
        }
        used.insert(candidate)
        return candidate
    }

    private static func parseAlternateURL(_ value: String) -> AlternateEndpoint? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var user = ""
        var host = trimmed
        if let at = trimmed.lastIndex(of: "@") {
            user = String(trimmed[..<at])
            host = String(trimmed[trimmed.index(after: at)...])
        }
        let port: Int
        if let colon = host.lastIndex(of: ":"),
           let parsed = Int(host[host.index(after: colon)...]) {
            port = parsed
            host = String(host[..<colon])
        } else {
            port = 22
        }
        guard !host.isEmpty else { return nil }
        return AlternateEndpoint(host: host, port: port, username: user)
    }

    func delete(_ server: ServerConfiguration) {
        let affectedIDs = [server.id] + servers
            .filter { $0.normalizedJumpServerIDs.contains(server.id) }
            .map(\.id)
        for serverID in affectedIDs {
            connectionAttempts.removeValue(forKey: serverID)
            activeConnectionTokens.removeValue(forKey: serverID)
            connectionStates[serverID] = .disconnected
        }
        servers.removeAll { $0.id == server.id }
        states.removeValue(forKey: server.id)
        connectionStates.removeValue(forKey: server.id)
        Task {
            await SSHConnectionService.live.disconnect(serverID: server.id)
            try? credentialStore.remove(for: server.id)
            try? await connectionStatsStore.clear(serverID: server.id)
        }
        persist()
    }

    func connect(
        _ server: ServerConfiguration,
        allowUnverifiedHostKey: Bool = false
    ) async {
        let startedAt = Date()
        let attempt = UUID()
        connectionAttempts[server.id] = attempt
        connectionStates[server.id] = .connecting

        do {
            guard let credential = try loadCredential(for: server) else {
                throw ServerConfigurationError.missingCredential
            }

            var connectionServer = server
            if allowUnverifiedHostKey {
                connectionServer.knownHostKey = nil
            }

            try await connectThroughJumpCandidates(
                server: connectionServer,
                credential: credential,
                attempt: attempt,
                allowUnverifiedHostKey: allowUnverifiedHostKey
            )
            guard connectionAttempts[server.id] == attempt else { return }
            guard let connectionToken = await SSHConnectionService.live.connectionToken(
                serverID: server.id
            ) else {
                guard connectionAttempts[server.id] == attempt else { return }
                connectionAttempts.removeValue(forKey: server.id)
                connectionStates[server.id] = .disconnected
                return
            }
            activeConnectionTokens[server.id] = connectionToken
            guard await SSHConnectionService.live.connectionToken(serverID: server.id)
                == connectionToken else {
                activeConnectionTokens.removeValue(forKey: server.id)
                guard connectionAttempts[server.id] == attempt else { return }
                connectionAttempts.removeValue(forKey: server.id)
                connectionStates[server.id] = .disconnected
                return
            }
            connectionStates[server.id] = .connected
            if allowUnverifiedHostKey {
                let acceptedKeys = await SSHConnectionService.live.takeAcceptedHostKeys(
                    serverID: server.id
                )
                guard connectionAttempts[server.id] == attempt else { return }
                persistAcceptedHostKeys(acceptedKeys)
            }
            await recordConnection(
                for: server,
                startedAt: startedAt,
                result: .success
            )
            guard connectionAttempts[server.id] == attempt else { return }
        } catch is CancellationError {
            guard connectionAttempts[server.id] == attempt else { return }
            connectionStates[server.id] = .disconnected
        } catch {
            guard connectionAttempts[server.id] == attempt else { return }
            let message = error.localizedDescription
            markJumpHostTrustFailure(error)
            await recordConnection(
                for: server,
                startedAt: startedAt,
                result: ConnectionResult.classify(message: message),
                errorMessage: message
            )
            guard connectionAttempts[server.id] == attempt else { return }
            connectionStates[server.id] = .failed(message)
        }
    }

    private func connectThroughJumpCandidates(
        server: ServerConfiguration,
        credential: ServerCredentialInput,
        attempt: UUID,
        allowUnverifiedHostKey: Bool
    ) async throws {
        guard connectionAttempts[server.id] == attempt else {
            throw CancellationError()
        }
        let jumpChains = try await resolveJumpChains(
            for: server
        )
        var lastError: Error?
        for jumpChain in jumpChains {
            try Task.checkCancellation()
            guard connectionAttempts[server.id] == attempt else {
                throw CancellationError()
            }
            do {
                try await SSHConnectionService.live.connect(
                    to: server,
                    credential: makeSSHCredential(credential),
                    knownHostKey: server.knownHostKey,
                    jumpChain: jumpChain,
                    allowUnverifiedHostKey: allowUnverifiedHostKey
                )
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard connectionAttempts[server.id] == attempt else {
                    throw CancellationError()
                }
                guard isRetryableJumpError(error) else {
                    throw error
                }
                lastError = error
            }
        }

        throw lastError ?? SSHTransportError.jumpServerMissing
    }

    private func isRetryableJumpError(_ error: Error) -> Bool {
        if let transportError = error as? SSHTransportError {
            switch transportError {
            case .hostKeyVerificationRequired,
                 .hostKeyFingerprintRequired(_),
                 .hostKeyMismatch(_),
                 .jumpHostFingerprintRequired(_, _),
                 .jumpHostMismatch(_, _),
                 .jumpCycle:
                return false
            case .jumpServerMissing:
                return true
            case .notConnected:
                return true
            default:
                break
            }
        }
        if let configurationError = error as? ServerConfigurationError,
           case .missingCredential = configurationError {
            return false
        }

        let message = error.localizedDescription.lowercased()
        return message.contains("timed out")
            || message.contains("timeout")
            || message.contains("连接超时")
            || message.contains("connection refused")
            || message.contains("network is unreachable")
            || message.contains("no route")
            || message.contains("host not found")
            || message.contains("could not connect")
            || message.contains("connection reset")
            || message.contains("connection closed")
            || message.contains("closed channel")
            || message.contains("socketexception")
            || message.contains("failed host lookup")
            || message.contains("forwardlocal")
             || message.contains("broken pipe")
    }

    private func markJumpHostTrustFailure(_ error: Error) {
        guard let transportError = error as? SSHTransportError else { return }
        let jumpID: UUID
        let message: String
        switch transportError {
        case let .jumpHostFingerprintRequired(serverID, fingerprint):
            jumpID = serverID
            message = "此服务器尚未受信任。指纹：\(fingerprint)"
        case let .jumpHostMismatch(serverID, fingerprint):
            jumpID = serverID
            message = "SSH 主机密钥已更改。指纹：\(fingerprint)"
        default:
            return
        }
        connectionStates[jumpID] = .failed(message)
    }

    private func resolveJumpChains(
        for server: ServerConfiguration,
        visited: Set<UUID> = []
    ) async throws -> [[SSHJumpHop]] {
        guard !visited.contains(server.id) else {
            throw SSHTransportError.jumpCycle
        }

        let nextVisited = visited.union([server.id])
        let jumpIDs = server.normalizedJumpServerIDs
        if jumpIDs.isEmpty {
            return [[]]
        }

        var chains: [[SSHJumpHop]] = []
        var lastError: Error?
        for jumpID in jumpIDs {
            do {
                guard !nextVisited.contains(jumpID),
                      let jumpServer = servers.first(where: { $0.id == jumpID }) else {
                    throw SSHTransportError.jumpServerMissing
                }
                guard let jumpCredential = try loadCredential(for: jumpServer) else {
                    throw ServerConfigurationError.missingCredential
                }
                let prefixes = try await resolveJumpChains(
                    for: jumpServer,
                    visited: nextVisited
                )
                let hop = SSHJumpHop(
                    server: jumpServer,
                    credential: makeSSHCredential(jumpCredential),
                    knownHostKey: jumpServer.knownHostKey
                )
                chains.append(contentsOf: prefixes.map { $0 + [hop] })
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ServerConfigurationError {
                if case .missingCredential = error { throw error }
                lastError = error
            } catch let error as SSHTransportError {
                if case .jumpServerMissing = error {
                    lastError = error
                } else {
                    throw error
                }
            } catch {
                lastError = error
            }
        }

        guard !chains.isEmpty else {
            throw lastError ?? SSHTransportError.jumpServerMissing
        }
        return chains
    }

    func connectAndRefresh(
        _ server: ServerConfiguration,
        allowUnverifiedHostKey: Bool = false
    ) async {
        await connect(server, allowUnverifiedHostKey: allowUnverifiedHostKey)
        guard connectionState(for: server) == .connected else { return }
        await refreshAll()
    }

    func disconnect(_ server: ServerConfiguration) async {
        let affectedIDs = Set(
            [server.id] + servers
                .filter { $0.normalizedJumpServerIDs.contains(server.id) }
                .map(\.id)
        )
        let disconnectAttempts = Dictionary(
            uniqueKeysWithValues: affectedIDs.map { ($0, UUID()) }
        )
        for serverID in affectedIDs {
            connectionAttempts[serverID] = disconnectAttempts[serverID]
            activeConnectionTokens.removeValue(forKey: serverID)
            connectionStates[serverID] = .disconnected
        }
        await SSHConnectionService.live.disconnect(serverID: server.id)
        for serverID in affectedIDs where connectionAttempts[serverID] == disconnectAttempts[serverID] {
            connectionAttempts.removeValue(forKey: serverID)
            connectionStates[serverID] = .disconnected
        }
    }

    func execute(_ command: String, on server: ServerConfiguration) async throws -> String {
        try await SSHConnectionService.live.execute(command, on: server.id)
    }

    func suspend(_ server: ServerConfiguration) async throws {
        try await SSHConnectionService.live.runScriptFunction(
            "SbSuspend",
            flag: "sp",
            on: server
        )
    }

    func shutdown(_ server: ServerConfiguration) async throws {
        try await SSHConnectionService.live.runScriptFunction(
            "SbShutdown",
            flag: "sd",
            on: server
        )
    }

    func reboot(_ server: ServerConfiguration) async throws {
        try await SSHConnectionService.live.runScriptFunction(
            "SbReboot",
            flag: "r",
            on: server
        )
    }

    func openTerminal(for server: ServerConfiguration) async throws -> SSHTerminalSession {
        try await SSHConnectionService.live.openTerminal(server: server)
    }

    func listDirectory(
        for server: ServerConfiguration,
        path: String
    ) async throws -> [RemoteFile] {
        try await SSHConnectionService.live.listDirectory(serverID: server.id, path: path)
    }

    func readFile(
        for server: ServerConfiguration,
        path: String
    ) async throws -> String {
        try await SSHConnectionService.live.readRemoteFile(serverID: server.id, path: path)
    }

    func homeDirectory(for server: ServerConfiguration, fallback: String) async throws -> String {
        try await SSHConnectionService.live.homeDirectory(
            serverID: server.id,
            username: server.username,
            fallback: fallback
        )
    }

    func downloadFile(
        for server: ServerConfiguration,
        remotePath: String,
        localURL: URL,
        progress: @escaping @Sendable (SFTPTransferProgress) -> Void
    ) async throws {
        try await SSHConnectionService.live.downloadRemoteFile(
            serverID: server.id,
            remotePath: remotePath,
            localURL: localURL,
            progress: progress
        )
    }

    func uploadFile(
        for server: ServerConfiguration,
        localURL: URL,
        remotePath: String,
        progress: @escaping @Sendable (SFTPTransferProgress) -> Void
    ) async throws {
        try await SSHConnectionService.live.uploadLocalFile(
            serverID: server.id,
            localURL: localURL,
            remotePath: remotePath,
            progress: progress
        )
    }

    func applySFTPMutation(
        _ mutation: SFTPRemoteMutation,
        on server: ServerConfiguration
    ) async throws {
        try await SSHConnectionService.live.applySFTPMutation(
            serverID: server.id,
            mutation: mutation
        )
    }

    func listProcesses(for server: ServerConfiguration) async throws -> [RemoteProcess] {
        try await SSHConnectionService.live.listProcesses(server: server)
    }

    func terminateProcess(
        _ process: RemoteProcess,
        on server: ServerConfiguration,
        signal: ProcessSignal = .terminate
    ) async throws {
        try await SSHConnectionService.live.terminateProcess(
            serverID: server.id,
            process: process,
            signal: signal
        )
    }

    func listSystemServices(for server: ServerConfiguration) async throws -> [RemoteSystemService] {
        try await SSHConnectionService.live.listSystemServices(serverID: server.id)
    }

    func controlSystemService(
        _ service: RemoteSystemService,
        on server: ServerConfiguration,
        action: SystemServiceAction
    ) async throws {
        try await SSHConnectionService.live.controlSystemService(
            serverID: server.id,
            unit: service.unit,
            action: action
        )
    }

    func listContainers(for server: ServerConfiguration) async throws -> [RemoteContainer] {
        try await SSHConnectionService.live.listDockerContainers(serverID: server.id)
    }

    func controlContainer(
        _ container: RemoteContainer,
        on server: ServerConfiguration,
        action: ContainerAction
    ) async throws {
        try await SSHConnectionService.live.controlDockerContainer(
            serverID: server.id,
            container: container,
            action: action
        )
    }

    func removeContainer(
        _ container: RemoteContainer,
        on server: ServerConfiguration,
        force: Bool
    ) async throws {
        try await SSHConnectionService.live.removeDockerContainer(
            serverID: server.id,
            container: container,
            force: force
        )
    }

    func fetchSystemServiceStatus(
        _ service: RemoteSystemService,
        on server: ServerConfiguration
    ) async throws -> String {
        try await SSHConnectionService.live.fetchSystemServiceStatus(
            serverID: server.id,
            unit: service.unit
        )
    }

    func listPVEResources(for server: ServerConfiguration) async throws -> [PVEResource] {
        try await SSHConnectionService.live.listPVEResources(
            serverID: server.id,
            enabled: server.pveEnabled
        )
    }

    func controlPVEResource(
        _ resource: PVEResource,
        on server: ServerConfiguration,
        action: PVEAction
    ) async throws {
        try await SSHConnectionService.live.controlPVEResource(
            serverID: server.id,
            resource: resource,
            action: action,
            enabled: server.pveEnabled
        )
    }

    private func makeSSHCredential(_ credential: ServerCredentialInput) -> SSHCredential {
        switch credential {
        case .password(let password):
            return .password(password)
        case .privateKey(let privateKey, let passphrase):
            return .privateKey(privateKey, passphrase: passphrase)
        }
    }

    private func loadCredential(for server: ServerConfiguration) throws -> ServerCredentialInput? {
        if case .privateKey(let keyID) = server.authentication,
           let record = try PrivateKeyStore.live.records().first(where: { $0.id == keyID }) {
            let secret = try PrivateKeyStore.live.secret(for: record)
            return .privateKey(secret.key, passphrase: secret.passphrase)
        }
        guard let stored = try credentialStore.load(for: server.id) else { return nil }
        switch (server.authentication, stored) {
        case (.password, .password):
            return stored
        case (.privateKey(id: _), .privateKey(_, passphrase: _)):
            return stored
        default:
            return nil
        }
    }

    private func persistAcceptedHostKeys(_ keys: [UUID: String]) {
        guard !keys.isEmpty else { return }
        var didChange = false
        for (serverID, key) in keys {
            guard let index = servers.firstIndex(where: { $0.id == serverID }) else { continue }
            if servers[index].knownHostKey != key {
                servers[index].knownHostKey = key
                didChange = true
            }
        }
        if didChange { persist() }
    }

    private func recordConnection(
        for server: ServerConfiguration,
        startedAt: Date,
        result: ConnectionResult,
        errorMessage: String = ""
    ) async {
        let durationMilliseconds = max(
            0,
            Int(Date().timeIntervalSince(startedAt) * 1_000)
        )
        let stat = ConnectionStat(
            serverID: server.id,
            serverName: server.name,
            timestamp: startedAt,
            result: result,
            errorMessage: errorMessage,
            durationMilliseconds: durationMilliseconds
        )
        try? await connectionStatsStore.record(stat)
    }

    private func persist() {
        let snapshot = servers
        let saveTask = enqueuePersistence(snapshot)
        Task { @MainActor [weak self] in
            do {
                try await saveTask.value
            } catch {
                self?.storageError = error.localizedDescription
            }
        }
    }

    private func enqueuePersistence(
        _ snapshot: [ServerConfiguration]
    ) -> Task<Void, Error> {
        let store = store
        let previousTask = persistTask
        let task = Task { () throws -> Void in
            if let previousTask {
                try? await previousTask.value
            }
            try Task.checkCancellation()
            try await store.save(snapshot)
        }
        persistTask = task
        return task
    }
}
