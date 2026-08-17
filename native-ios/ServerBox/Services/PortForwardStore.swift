import Foundation

actor PortForwardStore {
    static let live = PortForwardStore()

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            self.fileURL = applicationSupport
                .appendingPathComponent("ServerBox", isDirectory: true)
                .appendingPathComponent("port-forwards.json")
        }
    }

    func configurations(for serverID: UUID) throws -> [PortForwardConfiguration] {
        try loadAll().filter { $0.serverID == serverID }
    }

    func upsert(_ configuration: PortForwardConfiguration) throws {
        var configurations = try loadAll()
        if let index = configurations.firstIndex(where: { $0.id == configuration.id }) {
            configurations[index] = configuration
        } else {
            configurations.append(configuration)
        }
        try saveAll(configurations)
    }

    func remove(id: UUID) throws {
        let configurations = try loadAll().filter { $0.id != id }
        try saveAll(configurations)
    }

    private func loadAll() throws -> [PortForwardConfiguration] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            return try JSONDecoder().decode([PortForwardConfiguration].self, from: Data(contentsOf: fileURL))
        } catch {
            throw PortForwardStoreError.invalidData
        }
    }

    private func saveAll(_ configurations: [PortForwardConfiguration]) throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configurations).write(to: fileURL, options: .atomic)
        } catch {
            throw PortForwardStoreError.writeFailed
        }
    }
}

enum PortForwardStoreError: LocalizedError, Equatable, Sendable {
    case invalidData
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "Saved port forwarding rules could not be read."
        case .writeFailed:
            return "Port forwarding rules could not be saved."
        }
    }
}
