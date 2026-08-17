import Citadel
import Foundation
import NIO
import NIOSSH

actor SSHPortForwardService {
    static let live = SSHPortForwardService()

    private struct ActiveLocalForward {
        let serverID: UUID
        let host: String
        let port: Int
        let channel: Channel
        let connections: PortForwardConnectionRegistry
    }

    private struct ActiveRemoteForward {
        let serverID: UUID
        let host: String
        let port: Int
        let task: Task<Void, Never>
        let connections: PortForwardConnectionRegistry
        let token: UUID
    }

    private struct StoppingRemoteForward {
        let serverID: UUID
        let host: String
        let port: Int
        let task: Task<Void, Never>
    }

    private var localListeners: [UUID: ActiveLocalForward] = [:]
    private var remoteTasks: [UUID: ActiveRemoteForward] = [:]
    private var startTokens: [UUID: (token: UUID, serverID: UUID)] = [:]
    private var pendingRemoteTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingRemoteTaskIDs: [UUID: UUID] = [:]
    private var pendingRemoteReadiness: [UUID: PortForwardReadiness] = [:]
    private var pendingRemoteConnections: [UUID: PortForwardConnectionRegistry] = [:]
    private var pendingRemoteServers: [UUID: (serverID: UUID, host: String, port: Int)] = [:]
    private var pendingConnectionRegistries: [UUID: PortForwardConnectionRegistry] = [:]
    private var stoppingRemoteTasks: [UUID: StoppingRemoteForward] = [:]
    private var stoppingLocalBinds: Set<String> = []
    private var startingLocalBinds: Set<String> = []

    func start(_ configuration: PortForwardConfiguration) async throws {
        try configuration.validate()
        let token = UUID()
        startTokens[configuration.id] = (token, configuration.serverID)
        await cancelPendingRemoteTask(configuration.id)
        cancelPendingConnections(configuration.id)
        await stopActive(configuration.id)
        defer {
            if startTokens[configuration.id]?.token == token {
                startTokens.removeValue(forKey: configuration.id)
            }
        }

        let client = try await SSHConnectionService.live.client(serverID: configuration.serverID)
        try Task.checkCancellation()
        guard startTokens[configuration.id]?.token == token else {
            throw CancellationError()
        }
        switch configuration.type {
        case .local:
            guard let remoteHost = configuration.remoteHost,
                  let remotePort = configuration.remotePort else {
                throw PortForwardServiceError.invalidConfiguration
            }
            let connections = PortForwardConnectionRegistry()
            let bindKey = localBindKey(host: configuration.localHost, port: configuration.localPort)
            guard !hasStoppingLocalBind(host: configuration.localHost, port: configuration.localPort),
                  startingLocalBinds.insert(bindKey).inserted else {
                throw PortForwardServiceError.localStillStopping
            }
            defer { startingLocalBinds.remove(bindKey) }
            do {
                pendingConnectionRegistries[configuration.id] = connections
                let listener = try await makeLocalListener(
                    client: client,
                    configuration: configuration,
                    remoteHost: remoteHost,
                    remotePort: remotePort,
                    connections: connections
                )
                clearPendingConnectionRegistry(configuration.id, matching: connections)
                guard !Task.isCancelled,
                      startTokens[configuration.id]?.token == token else {
                    closeLocalListener(
                        listener,
                        host: configuration.localHost,
                        port: configuration.localPort
                    )
                    connections.closeAll()
                    throw CancellationError()
                }
                localListeners[configuration.id] = ActiveLocalForward(
                    serverID: configuration.serverID,
                    host: configuration.localHost,
                    port: configuration.localPort,
                    channel: listener,
                    connections: connections
                )
            } catch is CancellationError {
                clearPendingConnectionRegistry(configuration.id, matching: connections)
                throw CancellationError()
            } catch {
                clearPendingConnectionRegistry(configuration.id, matching: connections)
                throw PortForwardServiceError.localBindFailed(error.localizedDescription)
            }
        case .remote:
            guard let remoteHost = configuration.remoteHost,
                  let remotePort = configuration.remotePort else {
                throw PortForwardServiceError.invalidConfiguration
            }
            let forwardToken = UUID()
            guard !hasStoppingRemoteForward(
                serverID: configuration.serverID,
                host: remoteHost,
                port: remotePort
            ) else {
                throw PortForwardServiceError.remoteStillStopping
            }
            let (task, connections) = try await makeRemoteForward(
                client: client,
                configuration: configuration,
                remoteHost: remoteHost,
                remotePort: remotePort,
                token: forwardToken,
                startToken: token
            )
        guard !Task.isCancelled,
                  startTokens[configuration.id]?.token == token else {
                markStoppingRemote(
                    token: forwardToken,
                    serverID: configuration.serverID,
                    host: remoteHost,
                    port: remotePort,
                    task: task
                )
                task.cancel()
                connections.closeAll()
                throw CancellationError()
            }
            remoteTasks[configuration.id] = ActiveRemoteForward(
                serverID: configuration.serverID,
                host: remoteHost,
                port: remotePort,
                task: task,
                connections: connections,
                token: forwardToken
            )
        case .dynamic:
            let connections = PortForwardConnectionRegistry()
            let bindKey = localBindKey(host: configuration.localHost, port: configuration.localPort)
            guard !hasStoppingLocalBind(host: configuration.localHost, port: configuration.localPort),
                  startingLocalBinds.insert(bindKey).inserted else {
                throw PortForwardServiceError.localStillStopping
            }
            defer { startingLocalBinds.remove(bindKey) }
            do {
                pendingConnectionRegistries[configuration.id] = connections
                let listener = try await makeSOCKSListener(
                    client: client,
                    configuration: configuration,
                    connections: connections
                )
                clearPendingConnectionRegistry(configuration.id, matching: connections)
                guard !Task.isCancelled,
                      startTokens[configuration.id]?.token == token else {
                    closeLocalListener(
                        listener,
                        host: configuration.localHost,
                        port: configuration.localPort
                    )
                    connections.closeAll()
                    throw CancellationError()
                }
                localListeners[configuration.id] = ActiveLocalForward(
                    serverID: configuration.serverID,
                    host: configuration.localHost,
                    port: configuration.localPort,
                    channel: listener,
                    connections: connections
                )
            } catch is CancellationError {
                clearPendingConnectionRegistry(configuration.id, matching: connections)
                throw CancellationError()
            } catch {
                clearPendingConnectionRegistry(configuration.id, matching: connections)
                throw PortForwardServiceError.localBindFailed(error.localizedDescription)
            }
        }
    }

    func stop(_ id: UUID) async {
        startTokens.removeValue(forKey: id)
        await cancelPendingRemoteTask(id)
        cancelPendingConnections(id)
        await stopActive(id)
    }

    private func cancelPendingConnections(_ id: UUID) {
        guard let connections = pendingConnectionRegistries.removeValue(forKey: id) else {
            return
        }
        connections.closeAll()
    }

    private func clearPendingConnectionRegistry(
        _ id: UUID,
        matching connections: PortForwardConnectionRegistry
    ) {
        guard let current = pendingConnectionRegistries[id], current === connections else {
            return
        }
        pendingConnectionRegistries.removeValue(forKey: id)
    }

    private func cancelPendingRemoteTask(_ id: UUID) async {
        guard let taskToken = pendingRemoteTaskIDs.removeValue(forKey: id),
              let task = pendingRemoteTasks.removeValue(forKey: taskToken) else {
            return
        }
        let endpoint = pendingRemoteServers.removeValue(forKey: taskToken)
        if let endpoint {
            markStoppingRemote(
                token: taskToken,
                serverID: endpoint.serverID,
                host: endpoint.host,
                port: endpoint.port,
                task: task
            )
        }
        if let readiness = pendingRemoteReadiness.removeValue(forKey: taskToken) {
            await readiness.resolve(.failed("The remote forwarding setup was cancelled."))
        }
        if let connections = pendingRemoteConnections.removeValue(forKey: taskToken) {
            connections.closeAll()
        }
        task.cancel()
    }

    private func stopActive(_ id: UUID) async {
        if let listener = localListeners.removeValue(forKey: id) {
            closeLocalListener(
                listener.channel,
                host: listener.host,
                port: listener.port
            )
            listener.connections.closeAll()
        }
        if let task = remoteTasks.removeValue(forKey: id) {
            markStoppingRemote(
                token: task.token,
                serverID: task.serverID,
                host: task.host,
                port: task.port,
                task: task.task
            )
            task.task.cancel()
            task.connections.closeAll()
        }
    }

    func stopAll(serverID: UUID) async {
        let localIDs = localListeners.compactMap { id, forward in
            forward.serverID == serverID ? id : nil
        }
        let remoteIDs = remoteTasks.compactMap { id, forward in
            forward.serverID == serverID ? id : nil
        }
        let startingIDs = startTokens.compactMap { id, operation in
            operation.serverID == serverID ? id : nil
        }
        let ids = Set(localIDs).union(remoteIDs).union(startingIDs)
        for id in ids {
            await stop(id)
        }
    }

    func isActive(_ id: UUID) -> Bool {
        localListeners[id] != nil || remoteTasks[id] != nil
    }

    private func remoteTaskDidFinish(id: UUID, token: UUID) async {
        if let forward = remoteTasks[id], forward.token == token {
            remoteTasks.removeValue(forKey: id)
            forward.connections.closeAll()
        }
        stoppingRemoteTasks.removeValue(forKey: token)
    }

    private func markStoppingRemote(
        token: UUID,
        serverID: UUID,
        host: String,
        port: Int,
        task: Task<Void, Never>
    ) {
        stoppingRemoteTasks[token] = StoppingRemoteForward(
            serverID: serverID,
            host: host,
            port: port,
            task: task
        )
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await self?.expireStoppingRemote(token)
        }
    }

    private func expireStoppingRemote(_ token: UUID) {
        stoppingRemoteTasks.removeValue(forKey: token)
    }

    private func hasStoppingRemoteForward(
        serverID: UUID,
        host: String,
        port: Int
    ) -> Bool {
        stoppingRemoteTasks.values.contains {
            $0.serverID == serverID && $0.host == host && $0.port == port
        }
    }

    private func hasStoppingLocalBind(host: String, port: Int) -> Bool {
        let key = localBindKey(host: host, port: port)
        return stoppingLocalBinds.contains(key) || startingLocalBinds.contains(key)
    }

    private func closeLocalListener(_ channel: Channel, host: String, port: Int) {
        let key = localBindKey(host: host, port: port)
        stoppingLocalBinds.insert(key)
        channel.closeFuture.whenComplete { [weak self] _ in
            Task { [weak self] in
                await self?.clearStoppingLocalBind(key)
            }
        }
        channel.close(promise: nil)
    }

    private func clearStoppingLocalBind(_ key: String) {
        stoppingLocalBinds.remove(key)
    }

    private func localBindKey(host: String, port: Int) -> String {
        "\(host)\u{001F}\(port)"
    }

    private func makeLocalListener(
        client: SSHClient,
        configuration: PortForwardConfiguration,
        remoteHost: String,
        remotePort: Int,
        connections: PortForwardConnectionRegistry
    ) async throws -> Channel {
        try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let promise = channel.eventLoop.makePromise(of: Void.self)
                let localBridge = PortForwardPendingByteBufferHandler()
                do {
                    try channel.pipeline.syncOperations.addHandler(localBridge)
                } catch {
                    promise.fail(error)
                    return promise.futureResult
                }
                let setupID = UUID()
                let setupTask = Task {
                    defer { connections.removeSetup(setupID) }
                    do {
                        let originatorAddress: SocketAddress
                        if let remoteAddress = channel.remoteAddress {
                            originatorAddress = remoteAddress
                        } else {
                            originatorAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
                        }
                        let remoteChannel = try await client.createDirectTCPIPChannel(
                            using: SSHChannelType.DirectTCPIP(
                                targetHost: remoteHost,
                                targetPort: remotePort,
                                originatorAddress: originatorAddress
                            )
                        ) { remoteChannel in
                            guard connections.insert(remoteChannel) else {
                                remoteChannel.close(promise: nil)
                                return remoteChannel.eventLoop.makeFailedFuture(
                                    ChannelError.ioOnClosedChannel
                                )
                            }
                            remoteChannel.pipeline.addHandler(
                                PortForwardByteBufferHandler(peer: channel)
                            )
                        }
                        guard connections.insert(channel) else {
                            remoteChannel.close(promise: nil)
                            channel.close(promise: nil)
                            promise.fail(ChannelError.ioOnClosedChannel)
                            return
                        }
                        channel.eventLoop.execute {
                            guard channel.isActive else {
                                remoteChannel.close(promise: nil)
                                promise.fail(ChannelError.ioOnClosedChannel)
                                return
                            }
                            localBridge.attach(peer: remoteChannel)
                            promise.succeed(())
                        }
                    } catch {
                        promise.fail(error)
                        channel.close(promise: nil)
                    }
                }
                _ = connections.registerSetup(setupTask, id: setupID)
                return promise.futureResult
            }
            .bind(host: configuration.localHost, port: configuration.localPort)
            .get()
    }

    private func makeSOCKSListener(
        client: SSHClient,
        configuration: PortForwardConfiguration,
        connections: PortForwardConnectionRegistry
    ) async throws -> Channel {
        try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(
                    PortForwardSOCKS5Handler(
                        client: client,
                        connections: connections
                    )
                )
            }
            .bind(host: configuration.localHost, port: configuration.localPort)
            .get()
    }

    private func makeRemoteForward(
        client: SSHClient,
        configuration: PortForwardConfiguration,
        remoteHost: String,
        remotePort: Int,
        token: UUID,
        startToken: UUID
    ) async throws -> (Task<Void, Never>, PortForwardConnectionRegistry) {
        let connections = PortForwardConnectionRegistry()
        let readiness = PortForwardReadiness()
        let task = Task { [weak self] in
            do {
                try await client.withRemotePortForward(
                    host: remoteHost,
                    port: remotePort,
                    onOpen: { _ in
                        await readiness.resolve(.ready)
                    },
                    handleChannel: { channel, _ in
                        ClientBootstrap(group: channel.eventLoop)
                            .channelInitializer { localChannel in
                                guard connections.insert(localChannel) else {
                                    localChannel.close(promise: nil)
                                    return localChannel.eventLoop.makeFailedFuture(
                                        ChannelError.ioOnClosedChannel
                                    )
                                }
                                localChannel.pipeline.addHandler(
                                    PortForwardByteBufferHandler(peer: channel)
                                )
                            }
                            .connect(
                                host: configuration.localHost,
                                port: configuration.localPort
                            )
                            .flatMap { localChannel in
                                guard connections.insert(channel) else {
                                    localChannel.close(promise: nil)
                                    channel.close(promise: nil)
                                    return channel.eventLoop.makeFailedFuture(
                                        ChannelError.ioOnClosedChannel
                                    )
                                }
                                channel.pipeline.addHandler(
                                    PortForwardSSHDataCodec(peer: localChannel)
                                )
                            }
                            .flatMapErrorThrowing { error in
                                channel.close(promise: nil)
                                throw error
                            }
                    }
                )
                await readiness.resolve(.failed("The remote forwarding task ended before it became active."))
            } catch {
                await readiness.resolve(.failed(error.localizedDescription))
            }
            await self?.remoteTaskDidFinish(id: configuration.id, token: token)
        }

        pendingRemoteTaskIDs[configuration.id] = token
        pendingRemoteTasks[token] = task
        pendingRemoteReadiness[token] = readiness
        pendingRemoteConnections[token] = connections
        pendingRemoteServers[token] = (
            serverID: configuration.serverID,
            host: remoteHost,
            port: remotePort
        )
        defer {
            if pendingRemoteTaskIDs[configuration.id] == token {
                pendingRemoteTaskIDs.removeValue(forKey: configuration.id)
            }
            pendingRemoteTasks.removeValue(forKey: token)
            pendingRemoteReadiness.removeValue(forKey: token)
            pendingRemoteConnections.removeValue(forKey: token)
            pendingRemoteServers.removeValue(forKey: token)
        }

        let result = await withTaskCancellationHandler {
            await readiness.wait()
        } onCancel: {
            task.cancel()
            Task { [weak self] in
                await self?.markStoppingRemote(
                    token: token,
                    serverID: configuration.serverID,
                    host: remoteHost,
                    port: remotePort,
                    task: task
                )
                await readiness.resolve(.failed("The remote forwarding setup was cancelled."))
            }
        }
        if Task.isCancelled {
            markStoppingRemote(
                token: token,
                serverID: configuration.serverID,
                host: remoteHost,
                port: remotePort,
                task: task
            )
            task.cancel()
            connections.closeAll()
            throw CancellationError()
        }
        guard startTokens[configuration.id]?.token == startToken else {
            markStoppingRemote(
                token: token,
                serverID: configuration.serverID,
                host: remoteHost,
                port: remotePort,
                task: task
            )
            task.cancel()
            connections.closeAll()
            throw CancellationError()
        }

        switch result {
        case .ready:
            return (task, connections)
        case .failed(let message):
            markStoppingRemote(
                token: token,
                serverID: configuration.serverID,
                host: remoteHost,
                port: remotePort,
                task: task
            )
            task.cancel()
            connections.closeAll()
            throw PortForwardServiceError.remoteStartFailed(message)
        }
    }
}

private actor PortForwardReadiness {
    enum Result: Equatable, Sendable {
        case ready
        case failed(String)
    }

    private var result: Result?
    private var continuation: CheckedContinuation<Result, Never>?

    func wait() async -> Result {
        if let result {
            return result
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolve(_ result: Result) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(returning: result)
        continuation = nil
    }
}

private final class PortForwardConnectionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [ObjectIdentifier: Channel] = [:]
    private var setupTasks: [UUID: Task<Void, Never>] = [:]
    private var isClosed = false

    func registerSetup(_ task: Task<Void, Never>, id: UUID) -> Bool {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            task.cancel()
            return false
        }
        setupTasks[id] = task
        lock.unlock()
        return true
    }

    func removeSetup(_ id: UUID) {
        lock.lock()
        setupTasks.removeValue(forKey: id)
        lock.unlock()
    }

    func insert(_ channel: Channel) -> Bool {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return false
        }
        let identifier = ObjectIdentifier(channel)
        channels[identifier] = channel
        lock.unlock()
        channel.closeFuture.whenComplete { [weak self] _ in
            self?.remove(identifier)
        }
        return true
    }

    private func remove(_ identifier: ObjectIdentifier) {
        lock.lock()
        channels.removeValue(forKey: identifier)
        lock.unlock()
    }

    func closeAll() {
        lock.lock()
        isClosed = true
        let setupTasks = Array(self.setupTasks.values)
        self.setupTasks.removeAll()
        let channels = Array(self.channels.values)
        self.channels.removeAll()
        lock.unlock()

        for task in setupTasks {
            task.cancel()
        }
        for channel in channels {
            channel.close(promise: nil)
        }
    }
}

private final class PortForwardPendingByteBufferHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var peer: Channel?
    private var pending = ByteBufferAllocator().buffer(capacity: 0)

    func attach(peer: Channel) {
        self.peer = peer
        var buffered = pending
        pending.clear()
        if buffered.readableBytes > 0 {
            peer.writeAndFlush(buffered, promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let peer {
            peer.writeAndFlush(buffer, promise: nil)
        } else {
            pending.writeBuffer(&buffer)
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        peer?.flush()
        context.fireChannelReadComplete()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        peer?.close(promise: nil)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer?.close(promise: nil)
        context.fireChannelInactive()
    }
}

private final class PortForwardByteBufferHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let peer: Channel

    init(peer: Channel) {
        self.peer = peer
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        peer.writeAndFlush(unwrapInboundIn(data), promise: nil)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        peer.flush()
        context.fireChannelReadComplete()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        peer.close(promise: nil)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer.close(promise: nil)
        context.fireChannelInactive()
    }
}

private final class PortForwardSSHDataCodec: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let peer: Channel

    init(peer: Channel) {
        self.peer = peer
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = data.data else {
            context.fireErrorCaught(PortForwardServiceError.invalidChannelData)
            return
        }
        peer.writeAndFlush(buffer, promise: nil)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        peer.flush()
        context.fireChannelReadComplete()
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(
            wrapOutboundOut(
                SSHChannelData(type: .channel, data: .byteBuffer(buffer))
            ),
            promise: promise
        )
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        peer.close(promise: nil)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer.close(promise: nil)
        context.fireChannelInactive()
    }
}

private final class PortForwardSOCKS5Handler: ChannelInboundHandler, ChannelOutboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum State {
        case methods
        case request
        case connecting
        case connected
    }

    private let client: SSHClient
    private let connections: PortForwardConnectionRegistry
    private var state: State = .methods
    private var pending = ByteBufferAllocator().buffer(capacity: 0)
    private var requestIsInvalid = false
    private var connectedPeer: Channel?

    init(client: SSHClient, connections: PortForwardConnectionRegistry) {
        self.client = client
        self.connections = connections
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        pending.writeBuffer(&incoming)
        process(context: context)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(data, promise: promise)
    }

    private func process(context: ChannelHandlerContext) {
        switch state {
        case .methods:
            guard pending.readableBytes >= 2 else { return }
            var cursor = pending
            guard let version = cursor.readInteger(as: UInt8.self),
                  let methodCount = cursor.readInteger(as: UInt8.self) else {
                reject(context: context)
                return
            }
            guard cursor.readableBytes >= Int(methodCount) else { return }
            guard let methods = cursor.readBytes(length: Int(methodCount)) else { return }
            pending = cursor
            guard version == 5, methods.contains(0) else {
                var response = context.channel.allocator.buffer(capacity: 2)
                response.writeBytes([5, 255])
                context.writeAndFlush(wrapOutboundOut(response), promise: nil)
                context.close(promise: nil)
                return
            }
            var response = context.channel.allocator.buffer(capacity: 2)
            response.writeBytes([5, 0])
            context.writeAndFlush(wrapOutboundOut(response), promise: nil)
            state = .request
            process(context: context)

        case .request:
            guard pending.readableBytes >= 4 else { return }
            guard let request = parseRequest() else {
                if requestIsInvalid {
                    reject(context: context)
                }
                return
            }
            state = .connecting
            connect(request: request, context: context)

        case .connecting:
            return
        case .connected:
            guard let connectedPeer else { return }
            var buffered = pending
            pending.clear()
            if buffered.readableBytes > 0 {
                connectedPeer.writeAndFlush(buffered, promise: nil)
            }
        }
    }

    private func parseRequest() -> (host: String, port: Int)? {
        var cursor = pending
        requestIsInvalid = false
        guard let version = cursor.readInteger(as: UInt8.self),
              let command = cursor.readInteger(as: UInt8.self),
              let reserved = cursor.readInteger(as: UInt8.self),
              let addressType = cursor.readInteger(as: UInt8.self),
              version == 5,
              command == 1,
              reserved == 0 else {
            rejectPendingRequest()
            return nil
        }

        let host: String
        switch addressType {
        case 1:
            guard cursor.readableBytes >= 4,
                  let address = cursor.readBytes(length: 4) else { return nil }
            host = address.map(String.init).joined(separator: ".")
        case 3:
            guard let length = cursor.readInteger(as: UInt8.self),
                  cursor.readableBytes >= Int(length),
                  let address = cursor.readBytes(length: Int(length)),
                  let value = String(bytes: address, encoding: .utf8) else { return nil }
            host = value
        case 4:
            guard cursor.readableBytes >= 16,
                  let address = cursor.readBytes(length: 16) else { return nil }
            host = (0..<8).map { index in
                String(format: "%02x%02x", address[index * 2], address[index * 2 + 1])
            }.joined(separator: ":")
        default:
            rejectPendingRequest()
            return nil
        }

        guard let port = cursor.readInteger(as: UInt16.self) else { return nil }
        pending = cursor
        return (host, Int(port))
    }

    private func connect(
        request: (host: String, port: Int),
        context: ChannelHandlerContext
    ) {
        let eventLoop = context.eventLoop
        let channel = context.channel
        let client = client
        let setupID = UUID()
        let setupTask = Task {
            defer { connections.removeSetup(setupID) }
            do {
                let originatorAddress: SocketAddress
                if let remoteAddress = channel.remoteAddress {
                    originatorAddress = remoteAddress
                } else {
                    originatorAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
                }
                let remoteChannel = try await client.createDirectTCPIPChannel(
                    using: SSHChannelType.DirectTCPIP(
                        targetHost: request.host,
                        targetPort: request.port,
                        originatorAddress: originatorAddress
                    )
                ) { remoteChannel in
                    guard connections.insert(remoteChannel) else {
                        remoteChannel.close(promise: nil)
                        return remoteChannel.eventLoop.makeFailedFuture(
                            ChannelError.ioOnClosedChannel
                        )
                    }
                    remoteChannel.pipeline.addHandler(
                        PortForwardByteBufferHandler(peer: channel)
                    )
                }
                guard connections.insert(channel) else {
                    remoteChannel.close(promise: nil)
                    channel.close(promise: nil)
                    return
                }
                eventLoop.execute { [weak self] in
                    guard let self, channel.isActive else {
                        remoteChannel.close(promise: nil)
                        return
                    }
                    channel.pipeline.addHandler(
                        PortForwardByteBufferHandler(peer: remoteChannel)
                    ).whenComplete { [weak self] result in
                        guard let self else { return }
                        switch result {
                        case .success:
                            self.connectedPeer = remoteChannel
                            self.state = .connected
                            self.writeReply(context: context, code: 0)
                            var buffered = self.pending
                            self.pending.clear()
                            if buffered.readableBytes > 0 {
                                remoteChannel.writeAndFlush(buffered, promise: nil)
                            }
                            context.pipeline.removeHandler(self)
                        case .failure:
                            remoteChannel.close(promise: nil)
                            self.reject(context: context)
                        }
                    }
                }
            } catch {
                eventLoop.execute { [weak self] in
                    self?.reject(context: context)
                }
            }
        }
        if !connections.registerSetup(setupTask, id: setupID) {
            channel.close(promise: nil)
        }
    }

    private func writeReply(context: ChannelHandlerContext, code: UInt8) {
        var response = context.channel.allocator.buffer(capacity: 10)
        response.writeBytes([5, code, 0, 1, 0, 0, 0, 0])
        response.writeInteger(UInt16(0))
        context.writeAndFlush(wrapOutboundOut(response), promise: nil)
    }

    private func rejectPendingRequest() {
        requestIsInvalid = true
        pending.clear()
    }

    private func reject(context: ChannelHandlerContext) {
        writeReply(context: context, code: 1)
        context.close(promise: nil)
    }
}

// NIO invokes each handler on its channel's event loop; mutable parser state is loop-confined.
extension PortForwardByteBufferHandler: @unchecked Sendable {}
extension PortForwardPendingByteBufferHandler: @unchecked Sendable {}
extension PortForwardSSHDataCodec: @unchecked Sendable {}
extension PortForwardSOCKS5Handler: @unchecked Sendable {}

enum PortForwardServiceError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration
    case localBindFailed(String)
    case localStillStopping
    case remoteStartFailed(String)
    case remoteStillStopping
    case invalidChannelData

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "The port forwarding configuration is invalid."
        case .localBindFailed(let message):
            return "The local forwarding listener could not start: \(message)"
        case .localStillStopping:
            return "The previous local forwarding listener is still stopping. Try again shortly."
        case .remoteStartFailed(let message):
            return "The remote forwarding listener could not start: \(message)"
        case .remoteStillStopping:
            return "The previous remote forwarding listener is still stopping. Try again shortly."
        case .invalidChannelData:
            return "The SSH forwarding channel returned unsupported data."
        }
    }
}
