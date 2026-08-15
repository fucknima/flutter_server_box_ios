import Foundation

enum RemoteSystem: String, Codable, CaseIterable, Equatable, Sendable {
    case automatic
    case unix
    case windows
}

enum ServerAuthenticationReference: Codable, Equatable, Sendable {
    case password
    case privateKey(id: String)
}

struct ServerConfiguration: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var authentication: ServerAuthenticationReference
    var tags: [String]
    var alternateEndpoint: AlternateEndpoint?
    var autoConnect: Bool
    var jumpServerIDs: [UUID]
    var proxyCommand: String?
    var customCommands: [String: String]
    var environment: [String: String]
    var customSystem: RemoteSystem
    var disabledStatusTypes: Set<String>

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        authentication: ServerAuthenticationReference = .password,
        tags: [String] = [],
        alternateEndpoint: AlternateEndpoint? = nil,
        autoConnect: Bool = true,
        jumpServerIDs: [UUID] = [],
        proxyCommand: String? = nil,
        customCommands: [String: String] = [:],
        environment: [String: String] = [:],
        customSystem: RemoteSystem = .automatic,
        disabledStatusTypes: Set<String> = []
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authentication = authentication
        self.tags = tags
        self.alternateEndpoint = alternateEndpoint
        self.autoConnect = autoConnect
        self.jumpServerIDs = jumpServerIDs
        self.proxyCommand = proxyCommand
        self.customCommands = customCommands
        self.environment = environment
        self.customSystem = customSystem
        self.disabledStatusTypes = disabledStatusTypes
    }

    var normalizedJumpServerIDs: [UUID] {
        var seen = Set<UUID>()
        return jumpServerIDs.filter { seen.insert($0).inserted }.prefix(2).map { $0 }
    }

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ServerConfigurationError.emptyName
        }
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ServerConfigurationError.emptyHost
        }
        guard (1...65_535).contains(port) else {
            throw ServerConfigurationError.invalidPort
        }
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ServerConfigurationError.emptyUsername
        }
        if !normalizedJumpServerIDs.isEmpty,
           proxyCommand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            throw ServerConfigurationError.jumpAndProxyConflict
        }
    }

    func isSameConnection(as other: ServerConfiguration) -> Bool {
        host == other.host &&
            port == other.port &&
            username == other.username &&
            authentication == other.authentication &&
            normalizedJumpServerIDs == other.normalizedJumpServerIDs &&
            proxyCommand == other.proxyCommand
    }
}

struct AlternateEndpoint: Codable, Equatable, Sendable {
    var host: String
    var port: Int
    var username: String
}

enum ServerConfigurationError: LocalizedError, Equatable, Sendable {
    case emptyName
    case emptyHost
    case invalidPort
    case emptyUsername
    case jumpAndProxyConflict

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Enter a server name."
        case .emptyHost:
            return "Enter a server host."
        case .invalidPort:
            return "The port must be between 1 and 65535."
        case .emptyUsername:
            return "Enter an SSH username."
        case .jumpAndProxyConflict:
            return "A jump host and a proxy command cannot be used together."
        }
    }
}
