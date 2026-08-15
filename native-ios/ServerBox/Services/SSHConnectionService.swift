import Citadel
import Crypto
import Foundation
import NIO
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
    private var terminalSessions: [UUID: SSHTerminalSession] = [:]

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

        if let oldTerminal = terminalSessions.removeValue(forKey: server.id) {
            await oldTerminal.close()
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
        if let terminal = terminalSessions.removeValue(forKey: serverID) {
            await terminal.close()
        }
        guard let client = clients.removeValue(forKey: serverID) else { return }
        try? await client.close()
    }

    func disconnectAll() async {
        let activeClients = clients.values
        let activeTerminals = terminalSessions.values
        clients.removeAll()
        terminalSessions.removeAll()
        for terminal in activeTerminals {
            await terminal.close()
        }
        for client in activeClients {
            try? await client.close()
        }
    }

    func openTerminal(
        serverID: UUID,
        columns: Int = 100,
        rows: Int = 30
    ) async throws -> SSHTerminalSession {
        guard let client = clients[serverID], client.isConnected else {
            throw SSHTransportError.notConnected
        }

        if let oldTerminal = terminalSessions.removeValue(forKey: serverID) {
            await oldTerminal.close()
        }

        let terminal = SSHTerminalSession()
        terminalSessions[serverID] = terminal
        await terminal.start(client: client, columns: columns, rows: rows)
        return terminal
    }

    func closeTerminal(serverID: UUID) async {
        guard let terminal = terminalSessions.removeValue(forKey: serverID) else { return }
        await terminal.close()
    }

    func listDirectory(serverID: UUID, path: String) async throws -> [RemoteFile] {
        guard let client = clients[serverID], client.isConnected else {
            throw SSHTransportError.notConnected
        }

        return try await client.withSFTP { sftp in
            let names = try await sftp.listDirectory(atPath: path)
            return names
                .flatMap(\.components)
                .filter { $0.filename != "." && $0.filename != ".." }
                .map { component in
                    let permissions = component.attributes.permissions ?? 0
                    let isDirectory = component.longname.first == "d"
                        || (permissions & UInt32(0o170000)) == UInt32(0o040000)
                    let filePath = path == "/"
                        ? "/\(component.filename)"
                        : "\(path)/\(component.filename)"
                    return RemoteFile(
                        path: filePath,
                        name: component.filename,
                        isDirectory: isDirectory,
                        size: component.attributes.size,
                        modifiedAt: component.attributes.accessModificationTime?.modificationTime
                    )
                }
                .sorted {
                    if $0.isDirectory != $1.isDirectory {
                        return $0.isDirectory
                    }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
        }
    }

    func readRemoteFile(
        serverID: UUID,
        path: String,
        maxBytes: Int = 512 * 1024
    ) async throws -> String {
        guard let client = clients[serverID], client.isConnected else {
            throw SSHTransportError.notConnected
        }

        return try await client.withSFTP { sftp in
            try await sftp.withFile(filePath: path, flags: .read) { file in
                let buffer = try await file.readAll()
                guard buffer.readableBytes <= maxBytes else {
                    throw SFTPTransportError.fileTooLarge
                }
                return String(decoding: buffer.readableBytesView, as: UTF8.self)
            }
        }
    }

    func listProcesses(serverID: UUID) async throws -> [RemoteProcess] {
        let raw = try await execute(
            "ps -eo pid=,user=,%cpu=,%mem=,comm=,args= --sort=-%cpu 2>/dev/null || ps -axo pid,user,%cpu,%mem,command",
            on: serverID,
            maxResponseSize: 1024 * 1024
        )
        return RemoteProcessParser.parse(raw)
    }

    func terminateProcess(
        serverID: UUID,
        pid: Int,
        signal: ProcessSignal = .terminate
    ) async throws {
        guard pid > 0 else { throw ProcessControlError.invalidPID }
        _ = try await execute("kill -\(signal.rawValue) \(pid)", on: serverID)
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
    case jumpServerMissing
    case terminalNotOpen
    case hostKeyVerificationRequired
    case unsupportedPrivateKey

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "The server is not connected."
        case .jumpCycle:
            return "The jump-host chain contains a cycle."
        case .jumpServerMissing:
            return "A configured jump host could not be found."
        case .terminalNotOpen:
            return "The SSH terminal is not open."
        case .hostKeyVerificationRequired:
            return "This server has no trusted host key yet. Confirm its fingerprint before connecting."
        case .unsupportedPrivateKey:
            return "Only RSA and Ed25519 OpenSSH private keys are supported by the current transport."
        }
    }
}

struct RemoteFile: Equatable, Identifiable, Sendable {
    let path: String
    let name: String
    let isDirectory: Bool
    let size: UInt64?
    let modifiedAt: Date?

    var id: String { path }
}

struct RemoteProcess: Equatable, Identifiable, Sendable {
    let pid: Int
    let user: String
    let cpuPercent: Double
    let memoryPercent: Double
    let command: String

    var id: Int { pid }
}

enum ProcessSignal: Int, CaseIterable, Sendable {
    case terminate = 15
    case kill = 9
}

enum RemoteProcessParser {
    static func parse(_ raw: String) -> [RemoteProcess] {
        raw.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).compactMap { line in
            let fields = line.split(
                whereSeparator: { $0 == " " || $0 == "\t" },
                maxSplits: 5,
                omittingEmptySubsequences: true
            )
            guard fields.count >= 5,
                  let pid = Int(fields[0]),
                  pid > 0,
                  let cpu = Double(String(fields[2]).replacingOccurrences(of: ",", with: ".")),
                  let memory = Double(String(fields[3]).replacingOccurrences(of: ",", with: ".")) else {
                return nil
            }

            let command = fields.count > 5
                ? String(fields[5])
                : String(fields[4])
            return RemoteProcess(
                pid: pid,
                user: String(fields[1]),
                cpuPercent: cpu,
                memoryPercent: memory,
                command: command
            )
        }
    }
}

enum ProcessControlError: LocalizedError, Equatable, Sendable {
    case invalidPID

    var errorDescription: String? {
        "The process ID is invalid."
    }
}

enum SFTPTransportError: LocalizedError, Equatable, Sendable {
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return "This remote file is too large to preview on the device."
        }
    }
}

actor SSHTerminalSession {
    let output: AsyncThrowingStream<String, Error>

    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private var writer: TTYStdinWriter?
    private var task: Task<Void, Never>?
    private var didFinish = false

    init() {
        let stream = AsyncThrowingStream<String, Error>.makeStream()
        output = stream.stream
        continuation = stream.continuation
    }

    func start(client: SSHClient, columns: Int, rows: Int) {
        guard task == nil else { return }

        task = Task {
            do {
                let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    term: "xterm-256color",
                    terminalCharacterWidth: columns,
                    terminalRowHeight: rows,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0,
                    terminalModes: SSHTerminalModes([:])
                )

                try await client.withPTY(request) { inbound, outbound in
                    await self.setWriter(outbound)
                    do {
                        for try await event in inbound {
                            switch event {
                            case .stdout(let buffer), .stderr(let buffer):
                                let text = String(
                                    decoding: buffer.readableBytesView,
                                    as: UTF8.self
                                )
                                if !text.isEmpty {
                                    await self.emit(text)
                                }
                            }
                        }
                    } catch {
                        await self.finish(error)
                    }
                    await self.clearWriter()
                }
            } catch {
                await self.finish(error)
            }
            await self.finish(nil)
        }
    }

    func send(_ input: String) async throws {
        guard let writer else { throw SSHTransportError.terminalNotOpen }
        try await writer.write(ByteBuffer(string: input))
    }

    func resize(columns: Int, rows: Int) async throws {
        guard let writer else { throw SSHTransportError.terminalNotOpen }
        try await writer.changeSize(
            cols: columns,
            rows: rows,
            pixelWidth: 0,
            pixelHeight: 0
        )
    }

    func close() {
        task?.cancel()
        task = nil
        finish(nil)
    }

    private func setWriter(_ writer: TTYStdinWriter) {
        self.writer = writer
    }

    private func clearWriter() {
        writer = nil
    }

    private func emit(_ text: String) {
        guard !didFinish else { return }
        continuation.yield(text)
    }

    private func finish(_ error: Error?) {
        guard !didFinish else { return }
        didFinish = true
        writer = nil
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}
