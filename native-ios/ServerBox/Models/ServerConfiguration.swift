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
    var pveEnabled: Bool
    var disabledStatusTypes: Set<String>
    var statusURL: URL?
    var logoURL: URL?
    var isEnabled: Bool
    let createdAt: Date
    var knownHostKey: String?

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
        pveEnabled: Bool = false,
        disabledStatusTypes: Set<String> = [],
        statusURL: URL? = nil,
        logoURL: URL? = nil,
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        knownHostKey: String? = nil
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
        self.pveEnabled = pveEnabled
        self.disabledStatusTypes = disabledStatusTypes
        self.statusURL = statusURL
        self.logoURL = logoURL
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.knownHostKey = knownHostKey
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case host
        case port
        case username
        case authentication
        case tags
        case alternateEndpoint
        case autoConnect
        case jumpServerIDs
        case proxyCommand
        case customCommands
        case environment
        case customSystem
        case pveEnabled
        case disabledStatusTypes
        case statusURL
        case logoURL
        case isEnabled
        case createdAt
        case knownHostKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        authentication = try container.decode(
            ServerAuthenticationReference.self,
            forKey: .authentication
        )
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        alternateEndpoint = try container.decodeIfPresent(
            AlternateEndpoint.self,
            forKey: .alternateEndpoint
        )
        autoConnect = try container.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? true
        jumpServerIDs = try container.decodeIfPresent([UUID].self, forKey: .jumpServerIDs) ?? []
        proxyCommand = try container.decodeIfPresent(String.self, forKey: .proxyCommand)
        customCommands = try container.decodeIfPresent(
            [String: String].self,
            forKey: .customCommands
        ) ?? [:]
        environment = try container.decodeIfPresent(
            [String: String].self,
            forKey: .environment
        ) ?? [:]
        customSystem = try container.decodeIfPresent(RemoteSystem.self, forKey: .customSystem) ?? .automatic
        pveEnabled = try container.decodeIfPresent(Bool.self, forKey: .pveEnabled) ?? false
        disabledStatusTypes = try container.decodeIfPresent(
            Set<String>.self,
            forKey: .disabledStatusTypes
        ) ?? []
        statusURL = try container.decodeIfPresent(URL.self, forKey: .statusURL)
        logoURL = try container.decodeIfPresent(URL.self, forKey: .logoURL)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        knownHostKey = try container.decodeIfPresent(String.self, forKey: .knownHostKey)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(username, forKey: .username)
        try container.encode(authentication, forKey: .authentication)
        try container.encode(tags, forKey: .tags)
        try container.encodeIfPresent(alternateEndpoint, forKey: .alternateEndpoint)
        try container.encode(autoConnect, forKey: .autoConnect)
        try container.encode(jumpServerIDs, forKey: .jumpServerIDs)
        try container.encodeIfPresent(proxyCommand, forKey: .proxyCommand)
        try container.encode(customCommands, forKey: .customCommands)
        try container.encode(environment, forKey: .environment)
        try container.encode(customSystem, forKey: .customSystem)
        try container.encode(pveEnabled, forKey: .pveEnabled)
        try container.encode(disabledStatusTypes, forKey: .disabledStatusTypes)
        try container.encodeIfPresent(statusURL, forKey: .statusURL)
        try container.encodeIfPresent(logoURL, forKey: .logoURL)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(knownHostKey, forKey: .knownHostKey)
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
        if let statusURL {
            guard let scheme = statusURL.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  statusURL.host?.isEmpty == false else {
                throw ServerConfigurationError.invalidStatusURL
            }
        }
        if let logoURL {
            guard let scheme = logoURL.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  logoURL.host?.isEmpty == false else {
                throw ServerConfigurationError.invalidLogoURL
            }
        }
        if !normalizedJumpServerIDs.isEmpty,
           proxyCommand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            throw ServerConfigurationError.jumpAndProxyConflict
        }
        if proxyCommand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            throw ServerConfigurationError.proxyCommandUnsupported
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
    case invalidStatusURL
    case invalidLogoURL
    case missingCredential
    case jumpAndProxyConflict
    case proxyCommandUnsupported
    case duplicateBackupServer

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
        case .invalidStatusURL:
            return "Enter a valid HTTP or HTTPS status URL."
        case .invalidLogoURL:
            return "Enter a valid HTTP or HTTPS logo URL."
        case .missingCredential:
            return "Enter a password or private key for this server."
        case .jumpAndProxyConflict:
            return "A jump host and a proxy command cannot be used together."
        case .proxyCommandUnsupported:
            return "Proxy commands are not supported on iOS. Clear the proxy command or use jump hosts."
        case .duplicateBackupServer:
            return "The backup contains duplicate server identifiers."
        }
    }
}

enum ServerCredentialInput: Equatable, Sendable {
    case password(String)
    case privateKey(String, passphrase: String?)
}

struct ServerEditorDraft: Sendable {
    let configuration: ServerConfiguration
    let credential: ServerCredentialInput?
}

struct BulkImportServer: Codable, Sendable {
    let name: String
    let ip: String
    let port: Int
    let user: String
    let pwd: String
    let keyId: String
    let tags: [String]
    let alterUrl: String
    let autoConnect: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case ip
        case port
        case user
        case pwd
        case keyId
        case tags
        case alterUrl
        case autoConnect
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        ip = try container.decodeIfPresent(String.self, forKey: .ip) ?? ""
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 22
        user = try container.decodeIfPresent(String.self, forKey: .user) ?? "root"
        pwd = try container.decodeIfPresent(String.self, forKey: .pwd) ?? ""
        keyId = try container.decodeIfPresent(String.self, forKey: .keyId) ?? ""
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        alterUrl = try container.decodeIfPresent(String.self, forKey: .alterUrl) ?? ""
        autoConnect = try container.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? false
    }
}
