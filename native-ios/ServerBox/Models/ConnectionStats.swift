import Foundation

enum ConnectionResult: String, Codable, CaseIterable, Equatable, Sendable {
    case success
    case timeout
    case authFailed
    case networkError
    case unknownError

    var isSuccess: Bool {
        self == .success
    }

    var displayName: String {
        switch self {
        case .success:
            return "Success"
        case .timeout:
            return "Timeout"
        case .authFailed:
            return "Authentication failed"
        case .networkError:
            return "Network error"
        case .unknownError:
            return "Unknown error"
        }
    }

    static func classify(message: String) -> Self {
        let normalized = message.lowercased()
        if normalized.contains("timed out") || normalized.contains("timeout") {
            return .timeout
        }
        if normalized.contains("auth") ||
            normalized.contains("permission denied") ||
            normalized.contains("access denied") {
            return .authFailed
        }
        if normalized.contains("connection refused") ||
            normalized.contains("no route to host") ||
            normalized.contains("network") ||
            normalized.contains("socket") {
            return .networkError
        }
        return .unknownError
    }
}

struct ConnectionStat: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let serverID: UUID
    let serverName: String
    let timestamp: Date
    let result: ConnectionResult
    let errorMessage: String
    let durationMilliseconds: Int

    init(
        id: UUID = UUID(),
        serverID: UUID,
        serverName: String,
        timestamp: Date,
        result: ConnectionResult,
        errorMessage: String = "",
        durationMilliseconds: Int
    ) {
        self.id = id
        self.serverID = serverID
        self.serverName = serverName
        self.timestamp = timestamp
        self.result = result
        self.errorMessage = errorMessage
        self.durationMilliseconds = max(0, durationMilliseconds)
    }
}

struct ServerConnectionStats: Equatable, Identifiable, Sendable {
    let serverID: UUID
    let serverName: String
    let records: [ConnectionStat]

    var id: UUID { serverID }
    var totalAttempts: Int { records.count }
    var successCount: Int { records.count(where: { $0.result.isSuccess }) }
    var failureCount: Int { totalAttempts - successCount }
    var successRate: Double {
        guard totalAttempts > 0 else { return 0 }
        return Double(successCount) / Double(totalAttempts)
    }
    var lastSuccessTime: Date? {
        records.first(where: { $0.result.isSuccess })?.timestamp
    }
    var lastFailureTime: Date? {
        records.first(where: { !$0.result.isSuccess })?.timestamp
    }
    var recentConnections: [ConnectionStat] {
        Array(records.prefix(20))
    }

    init(serverID: UUID, serverName: String, records: [ConnectionStat]) {
        self.serverID = serverID
        self.serverName = serverName
        self.records = records.sorted { $0.timestamp > $1.timestamp }
    }
}
