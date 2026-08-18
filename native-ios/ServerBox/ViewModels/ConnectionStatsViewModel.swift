import Combine
import Foundation

@MainActor
final class ConnectionStatsViewModel: ObservableObject {
    @Published private(set) var serverStats: [ServerConnectionStats] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isCompacting = false
    @Published var errorMessage: String?

    private let store: ConnectionStatsStore

    init(store: ConnectionStatsStore = .live) {
        self.store = store
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            serverStats = try await store.allServerStats()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearAll() async {
        do {
            try await store.clearAll()
            serverStats = []
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clear(serverID: UUID) async {
        do {
            try await store.clear(serverID: serverID)
            serverStats = try await store.allServerStats()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func databaseSize() async -> Int64 {
        await store.databaseSize()
    }

    func compact() async -> CompactResult? {
        isCompacting = true
        defer { isCompacting = false }

        do {
            let before = await store.databaseSize()
            try await store.compact()
            let after = await store.databaseSize()
            serverStats = try await store.allServerStats()
            return CompactResult(beforeBytes: before, afterBytes: after)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}

struct CompactResult: Sendable {
    let beforeBytes: Int64
    let afterBytes: Int64
}
