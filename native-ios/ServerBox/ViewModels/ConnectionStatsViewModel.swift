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

    func compact() async {
        isCompacting = true
        defer { isCompacting = false }

        do {
            try await store.compact()
            serverStats = try await store.allServerStats()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
