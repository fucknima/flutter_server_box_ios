import Citadel
import Crypto
import Foundation
import NIO
import NIOSSH

private struct HostKeyRejected: Error {}

enum SSHCredential: Sendable {
    case password(String)
    case privateKey(String, passphrase: String?)
}

struct SSHJumpHop: Sendable {
    let server: ServerConfiguration
    let credential: SSHCredential
    let knownHostKey: String?
}

struct SSHDisconnectEvent: Sendable {
    let serverID: UUID
    let connectionToken: UUID
}

private final class HostKeyCapture: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var key: NIOSSHPublicKey?
    private var expectedKey: NIOSSHPublicKey?
    private let requireTrust: Bool

    init(expectedKey: NIOSSHPublicKey? = nil, requireTrust: Bool = false) {
        self.expectedKey = expectedKey
        self.requireTrust = requireTrust
    }

    func setExpectedKey(_ key: NIOSSHPublicKey?) {
        lock.lock()
        expectedKey = key
        lock.unlock()
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        lock.lock()
        key = hostKey
        let matchesExpectedKey = expectedKey.map { $0 == hostKey } ?? !requireTrust
        lock.unlock()
        if matchesExpectedKey {
            validationCompletePromise.succeed(())
        } else {
            validationCompletePromise.fail(HostKeyRejected())
        }
    }

    func openSSHKey() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let key else { return nil }

        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        key.write(to: &buffer)
        guard let algorithmLength = buffer.getInteger(
            at: buffer.readerIndex,
            as: UInt32.self
        ),
        let algorithmBytes = buffer.getBytes(
            at: buffer.readerIndex + 4,
            length: Int(algorithmLength)
        ),
        let algorithm = String(bytes: algorithmBytes, encoding: .utf8) else {
            return nil
        }
        return "\(algorithm) \(Data(buffer.readableBytesView).base64EncodedString())"
    }

    func fingerprint() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let key else { return nil }
        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        key.write(to: &buffer)
        let digest = SHA256.hash(data: Data(buffer.readableBytesView))
        return "SHA256:\(Data(digest).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "=")))"
    }
}

private struct AcceptedHostKeyBatch: Sendable {
    let connectionToken: UUID
    let keys: [UUID: String]
}

actor SSHConnectionService {
    static let live = SSHConnectionService()

    static let gbkEncoding: String.Encoding = {
        let cfEncoding = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }()

    private var clients: [UUID: SSHClient] = [:]
    private var clientChains: [UUID: [SSHClient]] = [:]
    private var clientChainServerIDs: [UUID: [UUID]] = [:]
    private var connectionTokens: [UUID: UUID] = [:]
    private var acceptedHostKeys: [UUID: AcceptedHostKeyBatch] = [:]
    private var terminalSessions: [UUID: SSHTerminalSession] = [:]
    private let disconnectStream: AsyncStream<SSHDisconnectEvent>
    private let disconnectContinuation: AsyncStream<SSHDisconnectEvent>.Continuation

    init() {
        let stream = AsyncStream<SSHDisconnectEvent>.makeStream()
        disconnectStream = stream.stream
        disconnectContinuation = stream.continuation
    }

    func unexpectedDisconnects() -> AsyncStream<SSHDisconnectEvent> {
        disconnectStream
    }

    func connectionToken(serverID: UUID) -> UUID? {
        guard let token = connectionTokens[serverID],
              clients[serverID]?.isConnected == true else {
            return nil
        }
        return token
    }

    func connect(
        to server: ServerConfiguration,
        credential: SSHCredential,
        knownHostKey: String?,
        jumpChain: [SSHJumpHop] = [],
        allowUnverifiedHostKey: Bool = false
    ) async throws {
        try server.validate()
        let jumpIDs = jumpChain.map(\.server.id)
        guard !jumpIDs.contains(server.id), Set(jumpIDs).count == jumpIDs.count else {
            throw SSHTransportError.jumpCycle
        }
        for hop in jumpChain {
            try hop.server.validate()
        }
        let previousToken = connectionTokens[server.id]
        let previousAcceptedKeys = acceptedHostKeys[server.id]
        let previousClient = clients[server.id]
        let connectionToken = UUID()
        connectionTokens[server.id] = connectionToken
        acceptedHostKeys.removeValue(forKey: server.id)

        var client: SSHClient?
        var clientChain: [SSHClient] = []
        var acceptedKeys: [UUID: String] = [:]
        do {
            let initialConnection = try await connectSingle(
                server: jumpChain.first?.server ?? server,
                credential: jumpChain.first?.credential ?? credential,
                knownHostKey: jumpChain.isEmpty
                    ? knownHostKey
                    : jumpChain.first?.knownHostKey,
                allowUnverifiedHostKey: jumpChain.isEmpty && allowUnverifiedHostKey,
                isJumpHost: jumpChain.first != nil
            )
            client = initialConnection.client
            if let client { clientChain.append(client) }
            if let firstHop = jumpChain.first,
               let acceptedKey = initialConnection.acceptedHostKey {
                acceptedKeys[firstHop.server.id] = acceptedKey
            } else if jumpChain.isEmpty,
                      let acceptedKey = initialConnection.acceptedHostKey {
                acceptedKeys[server.id] = acceptedKey
            }

            for hop in jumpChain.dropFirst() {
                let hostKeyCapture = HostKeyCapture(
                    requireTrust: hop.knownHostKey == nil
                )
                let settings = try makeSettings(
                    for: hop.server,
                    credential: hop.credential,
                    knownHostKey: hop.knownHostKey,
                    allowUnverifiedHostKey: false,
                    hostKeyCapture: hostKeyCapture
                )
                guard let currentClient = client else {
                    throw SSHTransportError.notConnected
                }
                do {
                    client = try await currentClient.jump(to: settings)
                } catch {
                    if error is HostKeyRejected,
                       let fingerprint = hostKeyCapture.fingerprint(),
                       hop.knownHostKey != nil {
                        throw SSHTransportError.jumpHostMismatch(
                            serverID: hop.server.id,
                            fingerprint: fingerprint
                        )
                    }
                    if error is HostKeyRejected,
                       let fingerprint = hostKeyCapture.fingerprint() {
                        throw SSHTransportError.jumpHostFingerprintRequired(
                            serverID: hop.server.id,
                            fingerprint: fingerprint
                        )
                    }
                    throw error
                }
                if let client { clientChain.append(client) }
            }

            if !jumpChain.isEmpty {
                let hostKeyCapture = HostKeyCapture(
                    requireTrust: !allowUnverifiedHostKey && knownHostKey == nil
                )
                let settings = try makeSettings(
                    for: server,
                    credential: credential,
                    knownHostKey: knownHostKey,
                    allowUnverifiedHostKey: allowUnverifiedHostKey,
                    hostKeyCapture: hostKeyCapture
                )
                guard let currentClient = client else {
                    throw SSHTransportError.notConnected
                }
                do {
                    client = try await currentClient.jump(to: settings)
                } catch {
                    if error is HostKeyRejected,
                       let fingerprint = hostKeyCapture.fingerprint(),
                       knownHostKey != nil {
                        throw SSHTransportError.hostKeyMismatch(fingerprint)
                    }
                    if error is HostKeyRejected,
                       let fingerprint = hostKeyCapture.fingerprint() {
                        throw SSHTransportError.hostKeyFingerprintRequired(fingerprint)
                    }
                    throw error
                }
                if let client { clientChain.append(client) }
                if allowUnverifiedHostKey,
                   let acceptedKey = hostKeyCapture.openSSHKey() {
                    acceptedKeys[server.id] = acceptedKey
                }
            }
            guard client?.isConnected == true else {
                throw SSHTransportError.notConnected
            }
        } catch {
            if connectionTokens[server.id] == connectionToken {
                if let previousClient, !previousClient.isConnected {
                    clients.removeValue(forKey: server.id)
                    let oldChain = clientChains.removeValue(forKey: server.id) ?? [previousClient]
                    clientChainServerIDs.removeValue(forKey: server.id)
                    connectionTokens.removeValue(forKey: server.id)
                    acceptedHostKeys.removeValue(forKey: server.id)
                    if let terminal = terminalSessions.removeValue(forKey: server.id) {
                        await terminal.close()
                    }
                    await SSHPortForwardService.live.stopAll(serverID: server.id)
                    for oldClient in oldChain.dropLast().reversed() {
                        closeClientInBackground(oldClient)
                    }
                } else if let previousToken {
                    connectionTokens[server.id] = previousToken
                    if let previousAcceptedKeys {
                        acceptedHostKeys[server.id] = previousAcceptedKeys
                    }
                } else {
                    connectionTokens.removeValue(forKey: server.id)
                    acceptedHostKeys.removeValue(forKey: server.id)
                }
            }
            for client in clientChain.reversed() {
                closeClientInBackground(client)
            }
            throw error
        }

        guard let client else {
            throw SSHTransportError.notConnected
        }

        guard connectionTokens[server.id] == connectionToken else {
            for client in clientChain.reversed() {
                closeClientInBackground(client)
            }
            throw CancellationError()
        }
        await SSHPortForwardService.live.stopAll(serverID: server.id)
        guard connectionTokens[server.id] == connectionToken else {
            for client in clientChain.reversed() {
                closeClientInBackground(client)
            }
            throw CancellationError()
        }
        if let oldTerminal = terminalSessions.removeValue(forKey: server.id) {
            await oldTerminal.close()
        }
        guard connectionTokens[server.id] == connectionToken else {
            for client in clientChain.reversed() {
                closeClientInBackground(client)
            }
            throw CancellationError()
        }
        guard client.isConnected else {
            for client in clientChain.reversed() {
                closeClientInBackground(client)
            }
            throw SSHTransportError.notConnected
        }
        let oldClient = clients.removeValue(forKey: server.id)
        clientChainServerIDs.removeValue(forKey: server.id)
        if let oldChain = clientChains.removeValue(forKey: server.id) {
            for oldChainClient in oldChain.reversed() {
                closeClientInBackground(oldChainClient)
            }
        } else if let oldClient {
            closeClientInBackground(oldClient)
        }
        client.onDisconnect { [weak client, weak self] in
            Task { [weak client, weak self] in
                guard let client else { return }
                await self?.handleUnexpectedDisconnect(
                    serverID: server.id,
                    client: client,
                    connectionToken: connectionToken
                )
            }
        }
        clients[server.id] = client
        clientChains[server.id] = clientChain
        clientChainServerIDs[server.id] = jumpChain.map(\.server.id) + [server.id]
        guard client.isConnected else {
            clients.removeValue(forKey: server.id)
            clientChains.removeValue(forKey: server.id)
            clientChainServerIDs.removeValue(forKey: server.id)
            acceptedHostKeys.removeValue(forKey: server.id)
            if connectionTokens[server.id] == connectionToken {
                connectionTokens.removeValue(forKey: server.id)
            }
            for upstreamClient in clientChain.dropLast().reversed() {
                closeClientInBackground(upstreamClient)
            }
            throw SSHTransportError.notConnected
        }
        if !acceptedKeys.isEmpty {
            acceptedHostKeys[server.id] = AcceptedHostKeyBatch(
                connectionToken: connectionToken,
                keys: acceptedKeys
            )
        }
    }

    func takeAcceptedHostKeys(serverID: UUID) -> [UUID: String] {
        guard let batch = acceptedHostKeys[serverID],
              connectionTokens[serverID] == batch.connectionToken,
              clients[serverID]?.isConnected == true else {
            acceptedHostKeys.removeValue(forKey: serverID)
            return [:]
        }
        acceptedHostKeys.removeValue(forKey: serverID)
        return batch.keys
    }

    func execute(
        _ command: String,
        on serverID: UUID,
        maxResponseSize: Int = 4 * 1024 * 1024
    ) async throws -> String {
        guard let client = clients[serverID], client.isConnected else {
            throw SSHTransportError.notConnected
        }
        return try await execute(
            command,
            using: client,
            maxResponseSize: maxResponseSize
        )
    }

    private func execute(
        _ command: String,
        using client: SSHClient,
        maxResponseSize: Int
    ) async throws -> String {
        do {
            let output = try await client.executeCommand(
                command,
                maxResponseSize: maxResponseSize,
                mergeStreams: true
            )
            return String(data: Data(output.readableBytesView), encoding: .utf8) ?? ""
        } catch {
            if error is SSHTransportError {
                throw error
            }
            let description = error.localizedDescription
            let isCommandFailure = description.contains("CommandFailed")
                || description.contains("command failed")
                || description.contains("exit status")
            if isCommandFailure {
                throw SSHTransportError.commandFailed("")
            }
            throw error
        }
    }

    func disconnect(serverID: UUID) async {
        let dependentIDs = clientChainServerIDs.compactMap { targetID, chainIDs in
            chainIDs.contains(serverID) ? targetID : nil
        }
        let serverIDs = Set(dependentIDs + [serverID])
        var activeChains: [[SSHClient]] = []
        var activeClients: [SSHClient] = []
        var activeTerminals: [SSHTerminalSession] = []
        var removedTokens: [UUID: UUID] = [:]

        for id in serverIDs {
            if let token = connectionTokens.removeValue(forKey: id) {
                removedTokens[id] = token
            }
            acceptedHostKeys.removeValue(forKey: id)
            if let client = clients.removeValue(forKey: id) {
                activeClients.append(client)
            }
            if let chain = clientChains.removeValue(forKey: id) {
                activeChains.append(chain)
            }
            clientChainServerIDs.removeValue(forKey: id)
            if let terminal = terminalSessions.removeValue(forKey: id) {
                activeTerminals.append(terminal)
            }
        }

        for (id, token) in removedTokens {
            disconnectContinuation.yield(
                SSHDisconnectEvent(serverID: id, connectionToken: token)
            )
        }

        for id in serverIDs {
            await SSHPortForwardService.live.stopAll(serverID: id)
        }
        for terminal in activeTerminals {
            await terminal.close()
        }
        for chain in activeChains {
            for client in chain.reversed() {
                closeClientInBackground(client)
            }
        }
        if activeChains.isEmpty {
            for client in activeClients {
                closeClientInBackground(client)
            }
        }
    }

    func disconnectAll() async {
        connectionTokens.removeAll()
        acceptedHostKeys.removeAll()
        let serverIDs = Set(clients.keys)
        let activeChains = Array(clientChains.values)
        let activeClients = Array(clients.values)
        let activeTerminals = Array(terminalSessions.values)
        clients.removeAll()
        clientChains.removeAll()
        clientChainServerIDs.removeAll()
        terminalSessions.removeAll()
        for serverID in serverIDs {
            await SSHPortForwardService.live.stopAll(serverID: serverID)
        }
        for terminal in activeTerminals {
            await terminal.close()
        }
        if activeChains.isEmpty {
            for client in activeClients {
                closeClientInBackground(client)
            }
        } else {
            for chain in activeChains {
                for client in chain.reversed() {
                    closeClientInBackground(client)
                }
            }
        }
    }

    func downloadRemoteFile(
        serverID: UUID,
        remotePath: String,
        localURL: URL,
        progress: @escaping @Sendable (SFTPTransferProgress) -> Void
    ) async throws {
        guard let client = clients[serverID], client.isConnected else {
            throw SSHTransportError.notConnected
        }

        let fileManager = FileManager.default
        let destinationURL = try validatedDownloadDestination(localURL, fileManager: fileManager)
        let parentDirectory = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parentDirectory,
            withIntermediateDirectories: true
        )

        let temporaryURL = parentDirectory.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).part"
        )
        guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw SFTPTransportError.downloadDestinationUnavailable
        }

        var didMoveTemporaryFile = false
        defer {
            if !didMoveTemporaryFile {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        try await client.withSFTP { sftp in
            try await sftp.withFile(filePath: remotePath, flags: .read) { file in
                let totalBytes = try await file.readAttributes().size
                var transferredBytes: UInt64 = 0
                let chunkSize: UInt32 = 64 * 1024
                let localFile = try FileHandle(forWritingTo: temporaryURL)
                var lastProgressAt = Date.distantPast

                func reportProgress(_ value: SFTPTransferProgress, force: Bool = false) {
                    let now = Date()
                    guard force || now.timeIntervalSince(lastProgressAt) >= 0.05 else { return }
                    lastProgressAt = now
                    progress(value)
                }

                defer { try? localFile.close() }
                reportProgress(
                    SFTPTransferProgress(
                        transferredBytes: 0,
                        totalBytes: totalBytes
                    ),
                    force: true
                )

                while totalBytes.map({ transferredBytes < $0 }) ?? true {
                    try Task.checkCancellation()
                    let buffer = try await file.read(
                        from: transferredBytes,
                        length: chunkSize
                    )
                    let bytesRead = buffer.readableBytes
                    if bytesRead == 0 {
                        if totalBytes == nil {
                            break
                        }
                        throw SFTPTransportError.downloadMadeNoProgress
                    }

                    try localFile.write(contentsOf: Data(buffer.readableBytesView))
                    transferredBytes += UInt64(bytesRead)
                    reportProgress(
                        SFTPTransferProgress(
                            transferredBytes: transferredBytes,
                            totalBytes: totalBytes
                        )
                    )
                }
                reportProgress(
                    SFTPTransferProgress(
                        transferredBytes: transferredBytes,
                        totalBytes: totalBytes
                    ),
                    force: true
                )
            }
        }

        try Task.checkCancellation()
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
        didMoveTemporaryFile = true
    }

    func uploadLocalFile(
        serverID: UUID,
        localURL: URL,
        remotePath: String,
        progress: @escaping @Sendable (SFTPTransferProgress) -> Void
    ) async throws {
        guard let client = clients[serverID], client.isConnected else {
            throw SSHTransportError.notConnected
        }

        let values = try localURL.resourceValues(
            forKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory != true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize >= 0 else {
            throw SFTPTransportError.localFileUnavailable
        }
        let totalBytes = UInt64(fileSize)
        let temporaryRemotePath = temporaryUploadPath(for: remotePath)

        try await client.withSFTP { sftp in
            let existingAttributes = try? await sftp.getAttributes(at: remotePath)
            do {
                try await sftp.withFile(
                    filePath: temporaryRemotePath,
                    flags: [.write, .create, .forceCreate]
                ) { remoteFile in
                    let localFile = try FileHandle(forReadingFrom: localURL)
                    let chunkSize = 64 * 1024
                    var transferredBytes: UInt64 = 0
                    var lastProgressAt = Date.distantPast

                    func reportProgress(_ value: SFTPTransferProgress, force: Bool = false) {
                        let now = Date()
                        guard force || now.timeIntervalSince(lastProgressAt) >= 0.05 else { return }
                        lastProgressAt = now
                        progress(value)
                    }

                    defer { try? localFile.close() }
                    reportProgress(
                        SFTPTransferProgress(
                            transferredBytes: 0,
                            totalBytes: totalBytes
                        ),
                        force: true
                    )

                    while transferredBytes < totalBytes {
                        try Task.checkCancellation()
                        guard let data = try localFile.read(upToCount: chunkSize), !data.isEmpty else {
                            throw SFTPTransportError.uploadMadeNoProgress
                        }

                        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                        buffer.writeBytes(data)
                        try await remoteFile.write(buffer, at: transferredBytes)
                        transferredBytes += UInt64(data.count)
                        reportProgress(
                            SFTPTransferProgress(
                                transferredBytes: transferredBytes,
                                totalBytes: totalBytes
                            )
                        )
                    }
                    reportProgress(
                        SFTPTransferProgress(
                            transferredBytes: transferredBytes,
                            totalBytes: totalBytes
                        ),
                        force: true
                    )
                }
                try Task.checkCancellation()
                if let permissions = existingAttributes?.permissions {
                    var attributes = SFTPFileAttributes()
                    attributes.permissions = permissions
                    try await sftp.setAttributes(at: temporaryRemotePath, to: attributes)
                }
                try await self.replaceRemoteFile(
                    sftp,
                    temporaryPath: temporaryRemotePath,
                    destinationPath: remotePath
                )
            } catch {
                try? await sftp.remove(at: temporaryRemotePath)
                throw error
            }
        }
    }

    func applySFTPMutation(
        serverID: UUID,
        mutation: SFTPRemoteMutation
    ) async throws {
        guard let client = clients[serverID], client.isConnected else {
            throw SSHTransportError.notConnected
        }

        try await client.withSFTP { sftp in
            switch mutation {
            case .createDirectory(let path):
                try await sftp.createDirectory(atPath: path)
            case .createFile(let path):
                try await sftp.withFile(
                    filePath: path,
                    flags: [.write, .create, .forceCreate]
                ) { _ in }
            case .rename(let oldPath, let newPath):
                try await sftp.rename(at: oldPath, to: newPath)
            case .remove(let path, let isDirectory, let recursive):
                if isDirectory {
                    if recursive {
                        try await self.removeRecursively(sftp, at: path)
                    } else {
                        try await sftp.rmdir(at: path)
                    }
                } else {
                    try await sftp.remove(at: path)
                }
            case .chmod(let path, let permissions):
                guard permissions <= 0o7777 else {
                    throw SFTPTransportError.invalidPermissions
                }
                var attributes = SFTPFileAttributes()
                attributes.permissions = permissions
                try await sftp.setAttributes(at: path, to: attributes)
            case .writeFile(let path, let content):
                let data = Data(content.utf8)
                guard data.count <= 1_048_576 else {
                    throw SFTPTransportError.fileTooLarge
                }
                let temporaryPath = self.temporaryUploadPath(for: path)
                let existingAttributes = try? await sftp.getAttributes(at: path)
                do {
                    try await sftp.withFile(
                        filePath: temporaryPath,
                        flags: [.write, .create, .forceCreate, .truncate]
                    ) { file in
                        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                        buffer.writeBytes(data)
                        try await file.write(buffer, at: 0)
                    }
                    try Task.checkCancellation()
                    if let permissions = existingAttributes?.permissions {
                        var attributes = SFTPFileAttributes()
                        attributes.permissions = permissions
                        try await sftp.setAttributes(at: temporaryPath, to: attributes)
                    }
                    try await self.replaceRemoteFile(
                        sftp,
                        temporaryPath: temporaryPath,
                        destinationPath: path
                    )
                } catch {
                    try? await sftp.remove(at: temporaryPath)
                    throw error
                }
            }
        }
    }

    func writeScriptFile(
        serverID: UUID,
        content: String,
        location: SrvBoxScript.ScriptLocation
    ) async throws {
        guard let client = clients[serverID], client.isConnected else {
            throw SSHTransportError.notConnected
        }
        try await client.withSFTP { sftp in
            let directory = location.directory
            let resolvedDirectory: String
            if directory.hasPrefix("~") {
                let home = try await self.execute(
                    "echo $HOME",
                    on: serverID,
                    maxResponseSize: 8192
                )
                let trimmed = home.trimmingCharacters(in: .whitespacesAndNewlines)
                resolvedDirectory = trimmed.isEmpty
                    ? "/root" + String(directory.dropFirst(2))
                    : trimmed + String(directory.dropFirst(2))
            } else {
                resolvedDirectory = directory
            }
            try await Self.makeDirectoryTree(
                sftp: sftp,
                path: resolvedDirectory
            )

            let path = "\(resolvedDirectory)/\(SrvBoxScript.scriptFileName)"
            let data = Data(content.utf8)
            try await sftp.withFile(
                filePath: path,
                flags: [.write, .create, .forceCreate, .truncate]
            ) { file in
                var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                buffer.writeBytes(data)
                try await file.write(buffer, at: 0)
            }
            var attributes = SFTPFileAttributes()
            attributes.permissions = 0o755
            try await sftp.setAttributes(at: path, to: attributes)
        }
    }

    private static func makeDirectoryTree(
        sftp: SFTPClient,
        path: String
    ) async throws {
        var current = ""
        for component in path.split(separator: "/") where !component.isEmpty {
            current += "/\(component)"
            if (try? await sftp.getAttributes(at: current)) != nil {
                continue
            }
            try await sftp.createDirectory(atPath: current)
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
        do {
            try await terminal.start(client: client, columns: columns, rows: rows)
            let snippets = (try? await SnippetStore.live.load()) ?? []
            for snippet in snippets where snippet.autoRunOn.contains(serverID) {
                let command = snippet.script.hasSuffix("\n")
                    ? snippet.script
                    : snippet.script + "\n"
                try? await terminal.send(command)
            }
            return terminal
        } catch {
            if let currentTerminal = terminalSessions[serverID], currentTerminal === terminal {
                terminalSessions.removeValue(forKey: serverID)
            }
            throw error
        }
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
                        modifiedAt: component.attributes.accessModificationTime?.modificationTime,
                        permissions: component.attributes.permissions
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
        maxBytes: Int = 1024 * 1024
    ) async throws -> String {
        guard let client = clients[serverID], client.isConnected else {
            throw SSHTransportError.notConnected
        }

        return try await client.withSFTP { sftp in
            try await sftp.withFile(filePath: path, flags: .read) { file in
                let attributes = try await file.readAttributes()
                if let size = attributes.size, size > UInt64(maxBytes) {
                    throw SFTPTransportError.fileTooLarge
                }
                var data = Data()
                var offset: UInt64 = 0
                let readLimit = UInt64(maxBytes + 1)
                while offset < readLimit {
                    let length = UInt32(min(64 * 1024, readLimit - offset))
                    let chunk = try await file.read(from: offset, length: length)
                    let bytesRead = chunk.readableBytes
                    if bytesRead == 0 { break }
                    data.append(contentsOf: chunk.readableBytesView)
                    offset += UInt64(bytesRead)
                    if offset > UInt64(maxBytes) {
                        throw SFTPTransportError.fileTooLarge
                    }
                    if let expectedSize = attributes.size, offset >= expectedSize {
                        break
                    }
                }
                guard let content = String(data: data, encoding: .utf8) else {
                    if let gbkContent = String(data: data, encoding: SSHConnectionService.gbkEncoding) {
                        return gbkContent
                    }
                    throw SFTPTransportError.notUTF8File
                }
                return content
            }
        }
    }

    func homeDirectory(
        serverID: UUID,
        username: String,
        fallback: String
    ) async throws -> String {
        let command = "getent passwd -- \(shellQuote(username)) | cut -d: -f6"
        let output: String
        do {
            output = try await execute(command, on: serverID, maxResponseSize: 8 * 1024)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return fallback
        }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? path : fallback
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
        process: RemoteProcess,
        signal: ProcessSignal = .terminate
    ) async throws {
        guard process.pid > 0 else { throw ProcessControlError.invalidPID }
        guard let client = clients[serverID], client.isConnected else {
            throw SSHTransportError.notConnected
        }
        let normalizedCommand = process.command
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
        let expectedIdentity = shellQuote("\(process.user) \(normalizedCommand)")
        let result = try await execute(
            "identity=$(ps -p \(process.pid) -o user=,args= | awk '{$1=$1;print}'); "
                + "if [ \"$identity\" = \(expectedIdentity) ]; then "
                + "kill -\(signal.rawValue) \(process.pid); "
                + "else printf 'SERVERBOX_PROCESS_CHANGED'; fi",
            using: client,
            maxResponseSize: 16 * 1024
        )
        guard !result.contains("SERVERBOX_PROCESS_CHANGED") else {
            throw ProcessControlError.processChanged
        }
    }

    func listSystemServices(serverID: UUID) async throws -> [RemoteSystemService] {
        let raw = try await execute(
            "systemctl list-units --type=service --all --no-legend --no-pager --plain",
            on: serverID,
            maxResponseSize: 1024 * 1024
        )
        return RemoteSystemServiceParser.parse(raw)
    }

    func controlSystemService(
        serverID: UUID,
        unit: String,
        action: SystemServiceAction
    ) async throws {
        guard RemoteSystemServiceParser.isSafeUnit(unit) else {
            throw SystemServiceControlError.invalidUnit
        }
        _ = try await execute("systemctl \(action.rawValue) \(unit)", on: serverID)
    }

    func listDockerContainers(serverID: UUID) async throws -> [RemoteContainer] {
        let runtime = try await containerRuntime(serverID: serverID)
        let raw = try await execute(
            "\(runtime) ps -a --format '{{.ID}}\\t{{.Names}}\\t{{.Image}}\\t{{.Status}}'",
            on: serverID,
            maxResponseSize: 1024 * 1024
        )
        return RemoteContainerParser.parse(raw, runtime: runtime)
    }

    func controlDockerContainer(
        serverID: UUID,
        container: RemoteContainer,
        action: ContainerAction
    ) async throws {
        guard RemoteContainerParser.isSafeIdentifier(container.identifier) else {
            throw ContainerControlError.invalidIdentifier
        }
        _ = try await execute(
            "\(container.runtime) \(action.rawValue) \(container.identifier)",
            on: serverID
        )
    }

    func removeDockerContainer(
        serverID: UUID,
        container: RemoteContainer
    ) async throws {
        guard RemoteContainerParser.isSafeIdentifier(container.identifier) else {
            throw ContainerControlError.invalidIdentifier
        }
        _ = try await execute(
            "\(container.runtime) rm -f \(container.identifier)",
            on: serverID
        )
    }

    func fetchContainerLogs(
        serverID: UUID,
        container: RemoteContainer
    ) async throws -> String {
        guard RemoteContainerParser.isSafeIdentifier(container.identifier) else {
            throw ContainerControlError.invalidIdentifier
        }
        return try await execute(
            "\(container.runtime) logs --tail 200 \(container.identifier) 2>&1 || true",
            on: serverID,
            maxResponseSize: 1024 * 1024
        )
    }

    func fetchSystemServiceStatus(
        serverID: UUID,
        unit: String
    ) async throws -> String {
        try await execute(
            "systemctl status \(unit) --no-pager 2>&1 || true",
            on: serverID,
            maxResponseSize: 1024 * 1024
        )
    }

    func listPVEResources(serverID: UUID, enabled: Bool) async throws -> [PVEResource] {
        guard enabled else { throw PVETransportError.disabled }
        let raw = try await execute(
            "pvesh get /cluster/resources --output-format json",
            on: serverID,
            maxResponseSize: 4 * 1024 * 1024
        )
        guard let start = raw.firstIndex(of: "["),
              let end = raw.lastIndex(of: "]") else {
            throw PVETransportError.invalidResponse
        }
        do {
            return try JSONDecoder().decode(
                [PVEResource].self,
                from: Data(raw[start...end].utf8)
            )
        } catch {
            throw PVETransportError.invalidResponse
        }
    }

    func controlPVEResource(
        serverID: UUID,
        resource: PVEResource,
        action: PVEAction,
        enabled: Bool
    ) async throws {
        guard enabled else { throw PVETransportError.disabled }
        guard resource.type == "qemu" || resource.type == "lxc",
              let vmid = resource.vmid,
              vmid > 0,
              isSafeRemoteIdentifier(resource.node) else {
            throw PVETransportError.invalidResource
        }
        _ = try await execute(
            "pvesh create /nodes/\(resource.node)/\(resource.type)/\(vmid)/status/\(action.rawValue)",
            on: serverID
        )
    }

    private func containerRuntime(serverID: UUID) async throws -> String {
        let raw = try await execute(
            "if command -v docker >/dev/null 2>&1; then printf docker; elif command -v podman >/dev/null 2>&1; then printf podman; else exit 127; fi",
            on: serverID
        )
        let runtime = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard runtime == "docker" || runtime == "podman" else {
            throw ContainerControlError.runtimeUnavailable
        }
        return runtime
    }

    func isConnected(serverID: UUID) -> Bool {
        clients[serverID]?.isConnected == true
    }

    func client(serverID: UUID) throws -> SSHClient {
        guard let client = clients[serverID], client.isConnected else {
            throw SSHTransportError.notConnected
        }
        return client
    }

    private func handleUnexpectedDisconnect(
        serverID: UUID,
        client: SSHClient,
        connectionToken: UUID
    ) async {
        guard let currentClient = clients[serverID], currentClient === client else { return }
        guard self.connectionTokens[serverID] == connectionToken else { return }
        clients.removeValue(forKey: serverID)
        let chain = clientChains.removeValue(forKey: serverID) ?? [client]
        clientChainServerIDs.removeValue(forKey: serverID)
        acceptedHostKeys.removeValue(forKey: serverID)
        let upstreamClients = chain.dropLast().reversed()
        if let terminal = terminalSessions.removeValue(forKey: serverID) {
            await terminal.close()
        }
        guard connectionTokens[serverID] == connectionToken,
              clients[serverID] == nil else {
            for upstreamClient in upstreamClients {
                closeClientInBackground(upstreamClient)
            }
            return
        }
        connectionTokens.removeValue(forKey: serverID)
        disconnectContinuation.yield(
            SSHDisconnectEvent(
                serverID: serverID,
                connectionToken: connectionToken
            )
        )
        await SSHPortForwardService.live.stopAll(serverID: serverID)
        for upstreamClient in upstreamClients {
            closeClientInBackground(upstreamClient)
        }
    }

    private func closeClientInBackground(_ client: SSHClient) {
        Task {
            try? await client.close()
        }
    }

    private func connectWithTimeout(
        to settings: SSHClientSettings,
        timeout: TimeInterval
    ) async throws -> SSHClient {
        try await withThrowingTaskGroup(of: SSHClient.self) { group in
            group.addTask {
                try await SSHClient.connect(to: settings)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw TimeoutError()
            }
            let result: SSHClient
            do {
                result = try await group.next()!
            } catch {
                group.cancelAll()
                throw error
            }
            group.cancelAll()
            try? await group.next()
            return result
        }
    }

    private struct TimeoutError: LocalizedError {
        var errorDescription: String? {
            "连接超时。"
        }
    }

    private func connectSingle(
        server: ServerConfiguration,
        credential: SSHCredential,
        knownHostKey: String?,
        allowUnverifiedHostKey: Bool,
        isJumpHost: Bool
    ) async throws -> (client: SSHClient, acceptedHostKey: String?) {
        let hostKeyCapture = HostKeyCapture(
            requireTrust: !allowUnverifiedHostKey && knownHostKey == nil
        )
        let settings = try makeSettings(
            for: server,
            credential: credential,
            knownHostKey: knownHostKey,
            allowUnverifiedHostKey: allowUnverifiedHostKey,
            hostKeyCapture: hostKeyCapture
        )
        do {
            let timeout = TimeInterval(SettingsStore.timeOut)
            let client = try await connectWithTimeout(to: settings, timeout: timeout)
            return (
                client,
                allowUnverifiedHostKey ? hostKeyCapture.openSSHKey() : nil
            )
        } catch {
            if error is HostKeyRejected,
               let fingerprint = hostKeyCapture.fingerprint(),
               knownHostKey != nil {
                if isJumpHost {
                    throw SSHTransportError.jumpHostMismatch(
                        serverID: server.id,
                        fingerprint: fingerprint
                    )
                }
                throw SSHTransportError.hostKeyMismatch(fingerprint)
            }
            if error is HostKeyRejected,
               let fingerprint = hostKeyCapture.fingerprint() {
                if isJumpHost {
                    throw SSHTransportError.jumpHostFingerprintRequired(
                        serverID: server.id,
                        fingerprint: fingerprint
                    )
                }
                throw SSHTransportError.hostKeyFingerprintRequired(fingerprint)
            }
            throw error
        }
    }

    private func makeSettings(
        for server: ServerConfiguration,
        credential: SSHCredential,
        knownHostKey: String?,
        allowUnverifiedHostKey: Bool,
        hostKeyCapture: HostKeyCapture? = nil
    ) throws -> SSHClientSettings {
        let authentication = try makeAuthentication(
            username: server.username,
            credential: credential
        )
        let validator: SSHHostKeyValidator
        if let knownHostKey {
            let key = try NIOSSHPublicKey(openSSHPublicKey: knownHostKey)
            hostKeyCapture?.setExpectedKey(key)
            if let hostKeyCapture {
                validator = .custom(hostKeyCapture)
            } else {
                validator = .trustedKeys([key])
            }
        } else if let hostKeyCapture {
            validator = .custom(hostKeyCapture)
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

    private func validatedDownloadDestination(
        _ localURL: URL,
        fileManager: FileManager
    ) throws -> URL {
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .standardizedFileURL
        let destinationURL = localURL.standardizedFileURL
        guard destinationURL.path.hasPrefix(documentsURL.path + "/") else {
            throw SFTPTransportError.invalidDownloadDestination
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            let values = try destinationURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory != true, values.isSymbolicLink != true else {
                throw SFTPTransportError.invalidDownloadDestination
            }
        }
        return destinationURL
    }

    private nonisolated func temporaryUploadPath(for remotePath: String) -> String {
        let components = remotePath.split(separator: "/")
        let fileName = components.last.map(String.init) ?? "upload"
        let directory = components.dropLast().isEmpty
            ? "/"
            : "/" + components.dropLast().joined(separator: "/")
        let temporaryName = ".serverbox-\(UUID().uuidString)-\(fileName).part"
        return directory == "/" ? "/\(temporaryName)" : "\(directory)/\(temporaryName)"
    }

    private nonisolated func removeRecursively(_ sftp: SFTPClient, at path: String) async throws {
        let entries = try await sftp.listDirectory(atPath: path)
        for component in entries.flatMap({ $0.components }) {
            guard component.filename != ".", component.filename != ".." else { continue }
            let childPath = path == "/"
                ? "/\(component.filename)"
                : "\(path)/\(component.filename)"
            let permissions = component.attributes.permissions ?? 0
            let isDirectory = component.longname.first == "d"
                || (permissions & UInt32(0o170000)) == UInt32(0o040000)
            if isDirectory {
                try await removeRecursively(sftp, at: childPath)
            } else {
                try await sftp.remove(at: childPath)
            }
        }
        try await sftp.rmdir(at: path)
    }

    private nonisolated func replaceRemoteFile(
        _ sftp: SFTPClient,
        temporaryPath: String,
        destinationPath: String
    ) async throws {
        try await sftp.rename(
            at: temporaryPath,
            to: destinationPath,
            flags: 0x00000001
        )
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func isSafeRemoteIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "."
        }
    }
}

enum SSHTransportError: LocalizedError, Equatable, Sendable {
    case notConnected
    case jumpCycle
    case jumpServerMissing
    case terminalNotOpen
    case hostKeyVerificationRequired
    case hostKeyFingerprintRequired(String)
    case hostKeyMismatch(String)
    case jumpHostFingerprintRequired(serverID: UUID, fingerprint: String)
    case jumpHostMismatch(serverID: UUID, fingerprint: String)
    case unsupportedPrivateKey
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "服务器未连接。"
        case .jumpCycle:
            return "跳板机链路存在循环。"
        case .jumpServerMissing:
            return "找不到配置的跳板机。"
        case .terminalNotOpen:
            return "SSH 终端未打开。"
        case .hostKeyVerificationRequired:
            return "此服务器还没有可信的主机密钥，连接前请确认其指纹。"
        case .hostKeyFingerprintRequired(let fingerprint):
            return "此服务器尚未受信任。指纹：\(fingerprint)"
        case .hostKeyMismatch(let fingerprint):
            return "SSH 主机密钥已更改。指纹：\(fingerprint)"
        case .jumpHostFingerprintRequired(_, let fingerprint):
            return "跳板机尚未受信任。指纹：\(fingerprint)"
        case .jumpHostMismatch(_, let fingerprint):
            return "跳板机密钥已更改。指纹：\(fingerprint)"
        case .unsupportedPrivateKey:
            return "当前传输层仅支持 RSA 和 Ed25519 的 OpenSSH 私钥。"
        case .commandFailed(let detail):
            if detail.isEmpty {
                return "远程命令执行失败。"
            }
            return "远程命令执行失败：\(detail)"
        }
    }
}

struct RemoteFile: Equatable, Identifiable, Sendable {
    let path: String
    let name: String
    let isDirectory: Bool
    let size: UInt64?
    let modifiedAt: Date?
    let permissions: UInt32?

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
    static func parseIdentity(_ raw: String) -> (user: String, command: String)? {
        let fields = raw.split(
            maxSplits: 2,
            omittingEmptySubsequences: true,
            whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
        )
        guard fields.count >= 2 else { return nil }
        let command = (fields.count == 3 ? String(fields[2]) : String(fields[1]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (user: String(fields[0]), command: command)
    }

    static func parse(_ raw: String) -> [RemoteProcess] {
        raw.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).compactMap { line in
            let fields = line.split(
                maxSplits: 5,
                omittingEmptySubsequences: true,
                whereSeparator: { $0 == " " || $0 == "\t" }
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
    case processChanged

    var errorDescription: String? {
        switch self {
        case .invalidPID:
            return "进程 ID 无效。"
        case .processChanged:
            return "进程已变更或不再可用，请刷新进程列表后重试。"
        }
    }
}

struct RemoteSystemService: Equatable, Identifiable, Sendable {
    let unit: String
    let activeState: String
    let subState: String
    let description: String

    var id: String { unit }
    var isActive: Bool { activeState == "active" }
}

enum SystemServiceAction: String, CaseIterable, Sendable {
    case start
    case stop
    case restart
}

enum RemoteSystemServiceParser {
    static func parse(_ raw: String) -> [RemoteSystemService] {
        raw.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).compactMap { line in
            let fields = line.split(
                maxSplits: 4,
                omittingEmptySubsequences: true,
                whereSeparator: { $0 == " " || $0 == "\t" }
            )
            guard fields.count >= 4,
                  fields[0].hasSuffix(".service") else {
                return nil
            }

            return RemoteSystemService(
                unit: String(fields[0]),
                activeState: String(fields[2]),
                subState: String(fields[3]),
                description: fields.count > 4 ? String(fields[4]) : ""
            )
        }
    }

    static func isSafeUnit(_ unit: String) -> Bool {
        !unit.isEmpty && unit.hasSuffix(".service") && unit.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" || $0 == "@"
        }
    }
}

enum SystemServiceControlError: LocalizedError, Equatable, Sendable {
    case invalidUnit

    var errorDescription: String? {
        "系统服务名称无效。"
    }
}

struct RemoteContainer: Equatable, Identifiable, Sendable {
    let identifier: String
    let name: String
    let image: String
    let status: String
    let runtime: String

    var id: String { identifier }
    var isRunning: Bool { status.lowercased().hasPrefix("up") }
}

enum ContainerAction: String, CaseIterable, Sendable {
    case start
    case stop
    case restart
}

enum RemoteContainerParser {
    static func parse(_ raw: String, runtime: String) -> [RemoteContainer] {
        raw.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4, !fields[0].isEmpty else { return nil }
            return RemoteContainer(
                identifier: String(fields[0]),
                name: String(fields[1]),
                image: String(fields[2]),
                status: String(fields[3]),
                runtime: runtime
            )
        }
    }

    static func isSafeIdentifier(_ identifier: String) -> Bool {
        !identifier.isEmpty && identifier.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_"
        }
    }
}

enum ContainerControlError: LocalizedError, Equatable, Sendable {
    case invalidIdentifier
    case runtimeUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidIdentifier:
            return "容器标识无效。"
        case .runtimeUnavailable:
            return "服务器上既没有 Docker 也没有 Podman。"
        }
    }
}

enum SFTPTransportError: LocalizedError, Equatable, Sendable {
    case fileTooLarge
    case downloadDestinationUnavailable
    case invalidDownloadDestination
    case downloadMadeNoProgress
    case localFileUnavailable
    case uploadMadeNoProgress
    case invalidPermissions
    case notUTF8File

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return "此远程文件过大，无法在设备上预览。"
        case .downloadDestinationUnavailable:
            return "无法在本地创建下载文件。"
        case .invalidDownloadDestination:
            return "下载目标必须是应用 Documents 文件夹内的普通文件。"
        case .downloadMadeNoProgress:
            return "下载过程中 SFTP 服务器停止返回数据。"
        case .localFileUnavailable:
            return "本地文件无法用于上传。"
        case .uploadMadeNoProgress:
            return "上传过程中本地文件停止返回数据。"
        case .invalidPermissions:
            return "权限必须是 0000 到 7777 之间的八进制值。"
        case .notUTF8File:
            return "此远程文件不是 UTF-8 文本文件，无法在此编辑。"
        }
    }
}

enum PVETransportError: LocalizedError, Equatable, Sendable {
    case disabled
    case invalidResponse
    case invalidResource

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "使用 PVE 前请先为此服务器启用 Proxmox 工具。"
        case .invalidResponse:
            return "服务器未返回有效的 Proxmox 资源数据。"
        case .invalidResource:
            return "Proxmox 资源标识无效。"
        }
    }
}

actor SSHTerminalSession {
    let output: AsyncThrowingStream<String, Error>

    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private var writer: TTYStdinWriter?
    private var task: Task<Void, Never>?
    private var didFinish = false
    private var finishError: Error?
    private var writerReadyContinuation: CheckedContinuation<Void, Error>?

    init() {
        let stream = AsyncThrowingStream<String, Error>.makeStream()
        output = stream.stream
        continuation = stream.continuation
    }

    func start(client: SSHClient, columns: Int, rows: Int) async throws {
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

        try await withTaskCancellationHandler {
            try await waitForWriter()
        } onCancel: {
            Task { await self.cancelStart() }
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
        if writer == nil && !didFinish {
            signalWriterReady(SSHTransportError.terminalNotOpen)
        }
        finish(nil)
    }

    private func setWriter(_ writer: TTYStdinWriter) {
        guard !didFinish else { return }
        self.writer = writer
        signalWriterReady(nil)
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
        finishError = error
        writer = nil
        if writerReadyContinuation != nil {
            signalWriterReady(error ?? SSHTransportError.terminalNotOpen)
        }
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }

    private func waitForWriter() async throws {
        if writer != nil { return }
        if didFinish {
            throw finishError ?? SSHTransportError.terminalNotOpen
        }
        try await withCheckedThrowingContinuation { continuation in
            writerReadyContinuation = continuation
        }
    }

    private func signalWriterReady(_ error: Error?) {
        guard let continuation = writerReadyContinuation else { return }
        writerReadyContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    private func cancelStart() {
        task?.cancel()
        signalWriterReady(CancellationError())
    }
}
