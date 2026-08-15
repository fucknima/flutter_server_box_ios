import Foundation

struct MonitorServer: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var statusURL: URL
    var isEnabled: Bool
    let createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        statusURL: URL,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.statusURL = statusURL
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }
}

enum MonitorEndpoint {
    static func normalizedURL(from input: String) throws -> URL {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, var components = URLComponents(string: value) else {
            throw MonitorEndpointError.invalidURL
        }

        guard let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil else {
            throw MonitorEndpointError.invalidURL
        }

        if components.path.isEmpty || components.path == "/" {
            components.path = "/status"
        }

        guard let url = components.url else {
            throw MonitorEndpointError.invalidURL
        }
        return url
    }
}

enum MonitorEndpointError: LocalizedError, Equatable {
    case invalidURL

    var errorDescription: String? {
        "Enter a valid HTTP or HTTPS status URL."
    }
}
