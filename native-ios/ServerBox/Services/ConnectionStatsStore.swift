import Foundation

actor ConnectionStatsStore {
    static let live = ConnectionStatsStore()

    private let fileURL: URL
    private let maxRecordsPerServer = 100
    private let retentionInterval: TimeInterval = 30 * 24 * 60 * 60
    private var records: [ConnectionStat] = []
    private var didLoad = false

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
                .appendingPathComponent("connection-stats.json")
        }
    }

    func record(_ stat: ConnectionStat) throws {
        try loadIfNeeded()
        records.append(stat)
        pruneOldRecords(referenceDate: Date())
        try persist()
    }

    func allServerStats() throws -> [ServerConnectionStats] {
        try loadIfNeeded()
        let grouped = Dictionary(grouping: records, by: \.serverID)
        return grouped.map { serverID, serverRecords in
            ServerConnectionStats(
                serverID: serverID,
                serverName: serverRecords.first?.serverName ?? "Unknown server",
                records: serverRecords
            )
        }
        .sorted {
            $0.serverName.localizedStandardCompare($1.serverName) == .orderedAscending
        }
    }

    func clearAll() throws {
        try loadIfNeeded()
        records.removeAll()
        try persist()
    }

    func clear(serverID: UUID) throws {
        try loadIfNeeded()
        records.removeAll { $0.serverID == serverID }
        try persist()
    }

    func compact() throws {
        try loadIfNeeded()
        pruneOldRecords(referenceDate: Date())
        try persist()
    }

    private func loadIfNeeded() throws {
        guard !didLoad else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            didLoad = true
            return
        }

        do {
            records = try makeDecoder().decode([ConnectionStat].self, from: Data(contentsOf: fileURL))
            didLoad = true
        } catch {
            throw ConnectionStatsStoreError.invalidData
        }
    }

    private func pruneOldRecords(referenceDate: Date) {
        let cutoff = referenceDate.addingTimeInterval(-retentionInterval)
        let grouped = Dictionary(
            grouping: records.filter { $0.timestamp >= cutoff },
            by: \.serverID
        )

        records = grouped.values.flatMap { serverRecords in
            serverRecords
                .sorted { $0.timestamp > $1.timestamp }
                .prefix(maxRecordsPerServer)
        }
        .sorted { $0.timestamp > $1.timestamp }
    }

    private func persist() throws {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try makeEncoder().encode(records).write(to: fileURL, options: .atomic)
        } catch {
            throw ConnectionStatsStoreError.writeFailed
        }
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

enum ConnectionStatsStoreError: LocalizedError, Equatable, Sendable {
    case invalidData
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "无法读取连接统计。"
        case .writeFailed:
            return "无法保存连接统计。"
        }
    }
}
