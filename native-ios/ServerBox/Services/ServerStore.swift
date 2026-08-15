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

    func load() throws -> [MonitorServer] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([MonitorServer].self, from: data)
        } catch {
            throw ServerStoreError.invalidData
        }
    }

    func save(_ servers: [MonitorServer]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(servers)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw ServerStoreError.writeFailed
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
