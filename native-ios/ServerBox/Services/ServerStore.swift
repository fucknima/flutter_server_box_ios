import Foundation

actor ServerStore {
    static let live = ServerStore()

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
                .appendingPathComponent("servers.json")
        }
    }

    func load() throws -> [ServerConfiguration] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: fileURL)
            return try makeDecoder().decode([ServerConfiguration].self, from: data)
        } catch {
            do {
                return try migrateMonitorServers(from: Data(contentsOf: fileURL))
            } catch {
                throw ServerStoreError.invalidData
            }
        }
    }

    func save(_ servers: [ServerConfiguration]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        do {
            let data = try makeEncoder().encode(servers)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw ServerStoreError.writeFailed
        }
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }

            let value = try container.decode(String.self)

            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractionalFormatter.date(from: value) {
                return date
            }

            let standardFormatter = ISO8601DateFormatter()
            standardFormatter.formatOptions = [.withInternetDateTime]
            guard let date = standardFormatter.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO8601 date."
                )
            }
            return date
        }
        return decoder
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSince1970)
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private func migrateMonitorServers(from data: Data) throws -> [ServerConfiguration] {
        let monitors = try makeDecoder().decode([MonitorServer].self, from: data)
        return monitors.compactMap { monitor in
            guard let host = monitor.statusURL.host, !host.isEmpty else { return nil }
            let port = monitor.statusURL.port
                ?? (monitor.statusURL.scheme?.lowercased() == "https" ? 443 : 80)
            return ServerConfiguration(
                id: monitor.id,
                name: monitor.name,
                host: host,
                port: port,
                username: "root",
                statusURL: monitor.statusURL,
                isEnabled: monitor.isEnabled,
                createdAt: monitor.createdAt
            )
        }
    }
}

enum ServerStoreError: LocalizedError, Equatable, Sendable {
    case invalidData
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "Saved server data could not be read."
        case .writeFailed:
            return "Server changes could not be saved."
        }
    }
}
