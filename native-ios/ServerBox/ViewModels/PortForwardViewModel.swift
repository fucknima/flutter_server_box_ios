import Combine
import Foundation

@MainActor
final class PortForwardViewModel: ObservableObject {
    @Published private(set) var configurations: [PortForwardConfiguration] = []
    @Published private(set) var statuses: [UUID: PortForwardStatus] = [:]
    @Published var errorMessage: String?

    private let serverID: UUID
    private let store: PortForwardStore
    private let service: SSHPortForwardService

    init(
        serverID: UUID,
        store: PortForwardStore = .live,
        service: SSHPortForwardService = .live
    ) {
        self.serverID = serverID
        self.store = store
        self.service = service
    }

    func load() async {
        do {
            configurations = try await store.configurations(for: serverID)
                .sorted {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            var loadedStatuses: [UUID: PortForwardStatus] = [:]
            for configuration in configurations {
                loadedStatuses[configuration.id] = await service.isActive(configuration.id)
                    ? .active
                    : .inactive
            }
            statuses = loadedStatuses
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshStatuses() async {
        for configuration in configurations {
            let active = await service.isActive(configuration.id)
            if active {
                statuses[configuration.id] = .active
            } else if statuses[configuration.id]?.isActive == true {
                statuses[configuration.id] = .inactive
            }
        }
    }

    func add(_ configuration: PortForwardConfiguration) async -> Bool {
        do {
            try configuration.validate()
            try await store.upsert(configuration)
            configurations.append(configuration)
            configurations.sort {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            statuses[configuration.id] = .inactive
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func update(_ configuration: PortForwardConfiguration) async -> Bool {
        guard let oldConfiguration = configurations.first(where: { $0.id == configuration.id }) else {
            return await add(configuration)
        }

        let wasActive = await service.isActive(configuration.id)
        await service.stop(configuration.id)
        do {
            try configuration.validate()
            try await store.upsert(configuration)
            configurations = configurations.map {
                $0.id == configuration.id ? configuration : $0
            }.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            statuses[configuration.id] = .inactive
            if wasActive {
                return await start(configuration)
            }
            errorMessage = nil
            return true
        } catch {
            configurations = configurations.map {
                $0.id == oldConfiguration.id ? oldConfiguration : $0
            }
            statuses[configuration.id] = .inactive
            if wasActive {
                _ = await start(oldConfiguration)
            }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func remove(_ configuration: PortForwardConfiguration) async -> Bool {
        let wasActive = await service.isActive(configuration.id)
        await service.stop(configuration.id)
        do {
            try await store.remove(id: configuration.id)
            configurations.removeAll { $0.id == configuration.id }
            statuses.removeValue(forKey: configuration.id)
            errorMessage = nil
            return true
        } catch {
            statuses[configuration.id] = .inactive
            if wasActive {
                _ = await start(configuration)
            }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func toggle(_ configuration: PortForwardConfiguration) async {
        if statuses[configuration.id]?.isActive == true {
            await service.stop(configuration.id)
            statuses[configuration.id] = .inactive
        } else {
            await start(configuration)
        }
    }

    private func start(_ configuration: PortForwardConfiguration) async -> Bool {
        statuses[configuration.id] = .starting
        do {
            try await service.start(configuration)
            guard configurations.contains(where: { $0.id == configuration.id }) else {
                return false
            }
            statuses[configuration.id] = .active
            errorMessage = nil
            return true
        } catch is CancellationError {
            if configurations.contains(where: { $0.id == configuration.id }) {
                statuses[configuration.id] = .inactive
            }
            return false
        } catch {
            if configurations.contains(where: { $0.id == configuration.id }) {
                statuses[configuration.id] = .failed(error.localizedDescription)
                errorMessage = error.localizedDescription
            }
            return false
        }
    }
}
