import Citadel
import Crypto
import Foundation
import NIOSSH

enum SSHCredential: Sendable {
    case password(String)
    case privateKey(String, passphrase: String?)
}

struct SSHJumpHop: Sendable {
    let server: ServerConfiguration
    let credential: SSHCredential
    let knownHostKey: String?
}

actor SSHConnectionService {
    static let live = SSHConnectionService()

    private var clients: [UUID: SSHClient] = [:]

    func connect(
        to server: ServerConfiguration,
        credential: SSHCredential,
        knownHostKey: String?,
        jumpChain: [SSHJumpHop] = [],
        allowUnverifiedHostKey: Bool = false
    ) async throws {
        try server.validate()
        guard !jumpChain.contains(where: { $0.server.id == server.id }) else {
            throw SSHTransportError.jumpCycle
        }

        var client = try await connectSingle(
            server: jumpChain.first?.server ?? server,
            credential: jumpChain.first?.credential ?? credential,
            knownHostKey: jumpChain.first?.knownHostKey ?? knownHostKey,
            allowUnverifiedHostKey: allowUnverifiedHostKey
        )

        for (index, hop) in jumpChain.dropFirst().enumerated() {
            guard !jumpChain.dropFirst(index + 1).contains(where: { $0.server.id == hop.server.id }) else {
                throw SSHTransportError.jumpCycle
            }
            let settings = try makeSettings(
                for: hop.server,
                credential: hop.credential,
                knownHostKey: hop.knownHostKey,
                allowUnverifiedHostKey: allowUnverifiedHostKey
            )
            client = try await client.jump(to: settings)
        }

        if !jumpChain.isEmpty {
            let settings = try makeSettings(
                for: server,
                credential: credential,
                knownHostKey: knownHostKey,
                allowUnverifiedHostKey: allowUnverifiedHostKey
            )
            client = try await client.jump(to: settings)
        }

        if let oldClient = clients[server.id] {
            try? await oldClient.close()
        }
        clients[server.id] = client
    }

    func execute(
        _ command: String,
        on serverID: UUID,
        maxResponseSize: Int = 4 * 1024 * 1024
    ) async throws -> String {
        guard let client = clients[serverID], client.isConnected else {
            throw SSHTransportError.notConnected
        }
        let output = try await client.executeCommand(
            command,
            maxResponseSize: maxResponseSize,
            mergeStreams: true
        )
        return String(data: Data(output.readableBytesView), encoding: .utf8) ?? ""
    }

    func disconnect(serverID: UUID) async {
        guard let client = clients.removeValue(forKey: serverID) else { return }
        try? await client.close()
    }

    func disconnectAll() async {
        let activeClients = clients.values
        clients.removeAll()
        for client in activeClients {
            try? await client.close()
        }
    }

    func isConnected(serverID: UUID) -> Bool {
        clients[serverID]?.isConnected == true
    }

    private func connectSingle(
        server: ServerConfiguration,
        credential: SSHCredential,
        knownHostKey: String?,
        allowUnverifiedHostKey: Bool
    ) async throws -> SSHClient {
        let settings = try makeSettings(
            for: server,
            credential: credential,
            knownHostKey: knownHostKey,
            allowUnverifiedHostKey: allowUnverifiedHostKey
        )
        return try await SSHClient.connect(to: settings)
    }

    private func makeSettings(
        for server: ServerConfiguration,
        credential: SSHCredential,
        knownHostKey: String?,
        allowUnverifiedHostKey: Bool
    ) throws -> SSHClientSettings {
        let authentication = try makeAuthentication(
            username: server.username,
            credential: credential
        )
        let validator: SSHHostKeyValidator
        if let knownHostKey {
            let key = try NIOSSHPublicKey(openSSHPublicKey: knownHostKey)
            validator = .trustedKeys([key])
        } else if allowUnverifiedHostKey {
            validator = .acceptAnything()
        } else {
            throw SSHTransportError.hostKeyVerificationRequired
        }

        return SSHClientSettings(
            host: server.host,
            port: server.port,
            authenticationMethod: { authentication },
            hostKeyValidator: validator
        )
    }

    private func makeAuthentication(
        username: String,
        credential: SSHCredential
    ) throws -> SSHAuthenticationMethod {
        switch credential {
        case .password(let password):
            return .passwordBased(username: username, password: password)
        case .privateKey(let pem, let passphrase):
            let decryptionKey = passphrase?.data(using: .utf8)
            if let key = try? Curve25519.Signing.PrivateKey(
                sshEd25519: pem,
                decryptionKey: decryptionKey
            ) {
                return .ed25519(username: username, privateKey: key)
            }
            if let key = try? Insecure.RSA.PrivateKey(
                sshRsa: pem,
                decryptionKey: decryptionKey
            ) {
                return .rsa(username: username, privateKey: key)
            }
            throw SSHTransportError.unsupportedPrivateKey
        }
    }
}

enum SSHTransportError: LocalizedError, Equatable, Sendable {
    case notConnected
    case jumpCycle
    case hostKeyVerificationRequired
    case unsupportedPrivateKey

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "The server is not connected."
        case .jumpCycle:
            return "The jump-host chain contains a cycle."
        case .hostKeyVerificationRequired:
            return "This server has no trusted host key yet. Confirm its fingerprint before connecting."
        case .unsupportedPrivateKey:
            return "Only RSA and Ed25519 OpenSSH private keys are supported by the current transport."
        }
    }
}
