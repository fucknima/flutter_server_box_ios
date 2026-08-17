import Foundation

enum PortForwardType: String, Codable, CaseIterable, Identifiable, Sendable {
    case local
    case remote
    case dynamic

    var id: String { rawValue }
}

struct PortForwardConfiguration: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let serverID: UUID
    var name: String
    var type: PortForwardType
    var localHost: String
    var localPort: Int
    var remoteHost: String?
    var remotePort: Int?

    init(
        id: UUID = UUID(),
        serverID: UUID,
        name: String,
        type: PortForwardType,
        localHost: String = "localhost",
        localPort: Int,
        remoteHost: String? = nil,
        remotePort: Int? = nil
    ) {
        self.id = id
        self.serverID = serverID
        self.name = name
        self.type = type
        self.localHost = localHost
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
    }

    var displayAddress: String {
        let local = "\(localHost):\(localPort)"
        switch type {
        case .local:
            return "\(local) -> \(remoteHost ?? "?"):\(remotePort.map(String.init) ?? "?")"
        case .remote:
            return "\(remoteHost ?? "?"):\(remotePort.map(String.init) ?? "?") -> \(local)"
        case .dynamic:
            return "\(local) (SOCKS5)"
        }
    }

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PortForwardConfigurationError.emptyName
        }
        guard !localHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PortForwardConfigurationError.emptyLocalHost
        }
        guard (1...65_535).contains(localPort) else {
            throw PortForwardConfigurationError.invalidLocalPort
        }

        guard type == .dynamic || (
            remoteHost?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                && remotePort.map { (1...65_535).contains($0) } == true
        ) else {
            throw PortForwardConfigurationError.invalidRemoteEndpoint
        }
    }
}

enum PortForwardConfigurationError: LocalizedError, Equatable, Sendable {
    case emptyName
    case emptyLocalHost
    case invalidLocalPort
    case invalidRemoteEndpoint

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Enter a port forward name."
        case .emptyLocalHost:
            return "Enter a local bind host."
        case .invalidLocalPort:
            return "The local port must be between 1 and 65535."
        case .invalidRemoteEndpoint:
            return "Enter a remote host and a port between 1 and 65535."
        }
    }
}

enum PortForwardStatus: Equatable, Sendable {
    case inactive
    case starting
    case active
    case failed(String)

    var isActive: Bool {
        self == .active
    }
}
