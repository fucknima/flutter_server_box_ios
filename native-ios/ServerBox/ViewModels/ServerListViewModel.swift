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
    private var didLoad = false
    private var refreshGeneration = 0

    init(
        store: ServerStore = .live,
        api: any MonitorAPIProtocol = MonitorAPI(),
        credentialStore: SSHCredentialStore = SSHCredentialStore(),
        sshStatusService: SSHStatusService = .live
    ) {
        self.store = store
        self.api = api
        self.credentialStore = credentialStore
        self.sshStatusService = sshStatusService
    }

    func start() async {
        await loadIfNeeded()

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
        guard !didLoad else { return }
        didLoad = true
        isLoading = true
        defer { isLoading = false }

        do {
            servers = try await store.load().sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
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

        for server in servers where server.isEnabled {
            guard !Task.isCancelled, generation == refreshGeneration else { return }

            guard let statusURL = server.statusURL else {
                guard connectionState(for: server) == .connected else {
                    states[server.id] = .idle
                    continue
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
                    states[server.id] = .failed(error.localizedDescription)
                }
                continue
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
                states[server.id] = .loaded(status)
            } catch is CancellationError {
                return
            } catch {
                guard generation == refreshGeneration else { return }
                states[server.id] = .failed(error.localizedDescription)
            }
        }
    }

    func state(for server: ServerConfiguration) -> ServerStatusState {
        states[server.id] ?? .idle
    }

    func connectionState(for server: ServerConfiguration) -> SSHConnectionState {
        connectionStates[server.id] ?? .disconnected
    }

    func save(_ draft: ServerEditorDraft) async throws {
        try draft.configuration.validate()

        let existingServer = servers.first { $0.id == draft.configuration.id }
        if let credential = draft.credential {
            try credentialStore.save(credential, for: draft.configuration.id)
        } else {
            let keepsExistingCredential: Bool
            if let existingServer,
               existingServer.authentication == draft.configuration.authentication {
                keepsExistingCredential = try credentialStore.load(for: draft.configuration.id) != nil
            } else {
                keepsExistingCredential = false
            }
            guard keepsExistingCredential else {
                throw ServerConfigurationError.missingCredential
            }
        }

        upsert(draft.configuration)
    }

    func upsert(_ server: ServerConfiguration) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
        servers.sort {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        states[server.id] = .idle
        connectionStates[server.id] = .disconnected
        persist()
    }

    func delete(_ server: ServerConfiguration) {
        servers.removeAll { $0.id == server.id }
        states.removeValue(forKey: server.id)
        connectionStates.removeValue(forKey: server.id)
        Task {
            await SSHConnectionService.live.disconnect(serverID: server.id)
            try? credentialStore.remove(for: server.id)
        }
        persist()
    }

    func connect(
        _ server: ServerConfiguration,
        allowUnverifiedHostKey: Bool = false
    ) async {
        connectionStates[server.id] = .connecting

        do {
            guard let credential = try credentialStore.load(for: server.id) else {
                throw ServerConfigurationError.missingCredential
            }

            var jumpChain: [SSHJumpHop] = []
            for jumpID in server.normalizedJumpServerIDs {
                guard let jumpServer = servers.first(where: { $0.id == jumpID }) else {
                    throw SSHTransportError.jumpServerMissing
                }
                guard let jumpCredential = try credentialStore.load(for: jumpID) else {
                    throw ServerConfigurationError.missingCredential
                }
                jumpChain.append(
                    SSHJumpHop(
                        server: jumpServer,
                        credential: makeSSHCredential(jumpCredential),
                        knownHostKey: jumpServer.knownHostKey
                    )
                )
            }

            try await SSHConnectionService.live.connect(
                to: server,
                credential: makeSSHCredential(credential),
                knownHostKey: server.knownHostKey,
                jumpChain: jumpChain,
                allowUnverifiedHostKey: allowUnverifiedHostKey
            )
            connectionStates[server.id] = .connected
        } catch is CancellationError {
            connectionStates[server.id] = .disconnected
        } catch {
            connectionStates[server.id] = .failed(error.localizedDescription)
        }
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
        await SSHConnectionService.live.disconnect(serverID: server.id)
        connectionStates[server.id] = .disconnected
    }

    func execute(_ command: String, on server: ServerConfiguration) async throws -> String {
        try await SSHConnectionService.live.execute(command, on: server.id)
    }

    func openTerminal(for server: ServerConfiguration) async throws -> SSHTerminalSession {
        try await SSHConnectionService.live.openTerminal(serverID: server.id)
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

    func listProcesses(for server: ServerConfiguration) async throws -> [RemoteProcess] {
        try await SSHConnectionService.live.listProcesses(serverID: server.id)
    }

    func terminateProcess(
        _ process: RemoteProcess,
        on server: ServerConfiguration,
        signal: ProcessSignal = .terminate
    ) async throws {
        try await SSHConnectionService.live.terminateProcess(
            serverID: server.id,
            pid: process.pid,
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

    private func makeSSHCredential(_ credential: ServerCredentialInput) -> SSHCredential {
        switch credential {
        case .password(let password):
            return .password(password)
        case .privateKey(let privateKey, let passphrase):
            return .privateKey(privateKey, passphrase: passphrase)
        }
    }

    private func persist() {
        let snapshot = servers
        let store = store
        Task { [weak self] in
            do {
                try await store.save(snapshot)
            } catch {
                self?.storageError = error.localizedDescription
            }
        }
    }
}
