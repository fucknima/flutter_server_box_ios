import Combine
import Foundation

@MainActor
final class ServerListViewModel: ObservableObject {
    @Published private(set) var servers: [MonitorServer] = []
    @Published private(set) var states: [UUID: ServerStatusState] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published var storageError: String?

    private let store: ServerStore
    private let api: any MonitorAPIProtocol
    private var didLoad = false
    private var refreshGeneration = 0

    init(
        store: ServerStore = .live,
        api: any MonitorAPIProtocol = MonitorAPI()
    ) {
        self.store = store
        self.api = api
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
            states[server.id] = .loading

            do {
                let status = try await api.fetchStatus(for: server)
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

    func state(for server: MonitorServer) -> ServerStatusState {
        states[server.id] ?? .idle
    }

    func upsert(_ server: MonitorServer) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
        servers.sort {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        states[server.id] = .idle
        persist()
    }

    func delete(_ server: MonitorServer) {
        servers.removeAll { $0.id == server.id }
        states.removeValue(forKey: server.id)
        persist()
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
