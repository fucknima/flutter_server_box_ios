import Foundation
import Testing
@testable import ServerBox

struct ServerBoxTests {
    @Test
    func monitorStatusPayloadDecodesAndCalculatesFractions() throws {
        let data = Data(
            """
            {
              "code": 0,
              "msg": "ok",
              "data": {
                "name": "home",
                "cpu": "31.7%",
                "mem": "1.3g / 1.9g",
                "disk": "7.1g / 30.0g",
                "net": "712.3k / 1.2m"
              }
            }
            """.utf8
        )

        let envelope = try JSONDecoder().decode(MonitorStatusEnvelope.self, from: data)

        #expect(envelope.code == 0)
        #expect(envelope.data?.name == "home")
        #expect(abs((envelope.data?.cpuFraction ?? 0) - 0.317) < 0.001)
        #expect(abs((envelope.data?.memoryFraction ?? 0) - (1.3 / 1.9)) < 0.001)
    }

    @Test
    func rootEndpointIsNormalizedToStatus() throws {
        let url = try MonitorEndpoint.normalizedURL(from: "https://example.com")
        #expect(url.absoluteString == "https://example.com/status")
    }

    @Test
    func invalidEndpointIsRejected() {
        #expect(throws: MonitorEndpointError.self) {
            try MonitorEndpoint.normalizedURL(from: "example.com")
        }
        #expect(throws: MonitorEndpointError.self) {
            try MonitorEndpoint.normalizedURL(from: "ftp://example.com")
        }
    }

    @Test
    func serverConfigurationKeepsJumpAndProxyModesExclusive() {
        let configuration = ServerConfiguration(
            name: "Jumped server",
            host: "example.com",
            username: "root",
            jumpServerIDs: [UUID()],
            proxyCommand: "socat - PROXY:proxy:22"
        )

        #expect(throws: ServerConfigurationError.self) {
            try configuration.validate()
        }
    }

    @Test
    func serverConfigurationRejectsProxyCommandOnIOS() {
        let configuration = ServerConfiguration(
            name: "Proxied server",
            host: "example.com",
            username: "root",
            proxyCommand: "socat - PROXY:proxy:22"
        )

        #expect(throws: ServerConfigurationError.proxyCommandUnsupported) {
            try configuration.validate()
        }
    }

    @Test
    func normalizedJumpServerIDsPreserveCandidateOrder() {
        let first = UUID()
        let second = UUID()
        let configuration = ServerConfiguration(
            name: "Jumped server",
            host: "example.com",
            username: "root",
            jumpServerIDs: [second, first, second]
        )

        #expect(configuration.normalizedJumpServerIDs == [second, first])
    }

    @Test
    func serverStoreRoundTripsCodableData() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerBoxTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("servers.json")
        let store = ServerStore(fileURL: fileURL)
        let statusURL = try #require(URL(string: "https://example.com/status"))
        let server = ServerConfiguration(
            name: "Test",
            host: "example.com",
            username: "root",
            statusURL: statusURL
        )

        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.save([server])
        let loaded = try await store.load()
        let loadedServer = try #require(loaded.first)

        #expect(loadedServer.id == server.id)
        #expect(loadedServer.name == server.name)
        #expect(loadedServer.host == server.host)
        #expect(loadedServer.statusURL == server.statusURL)
        #expect(loadedServer.isEnabled == server.isEnabled)
        #expect(abs(loadedServer.createdAt.timeIntervalSince(server.createdAt)) < 0.001)
    }

    @Test
    @MainActor
    func localFilesRejectPathTraversalWhenCreatingItems() {
        let viewModel = LocalFilesViewModel()

        viewModel.createItem(named: "../escape", directory: false)

        #expect(viewModel.errorMessage != nil)
    }

    @Test
    func sshStatusProtocolParsesFramedSections() throws {
        let raw = """
        SrvBoxSep.b64.aG9zdA==
        SrvBoxData.server-one
        SrvBoxSep.b64.Y3B1
        SrvBoxData.31.5%
        SrvBoxSep.b64.bWVtb3J5
        SrvBoxData.1.3G / 4.0G
        SrvBoxSep.b64.ZGlzaw==
        SrvBoxData.7.1G / 30.0G
        SrvBoxSep.b64.bmV0d29yaw==
        SrvBoxData.1.2M / 3.4M
        """

        let status = try SSHStatusProtocol.parse(raw, fallbackName: "fallback")

        #expect(status.name == "server-one")
        #expect(status.cpu == "31.5%")
        #expect(status.memory == "1.3G / 4.0G")
        #expect(status.disk == "7.1G / 30.0G")
        #expect(status.network == "1.2M / 3.4M")
    }

    @Test
    func remoteProcessParserKeepsCommandArguments() {
        let processes = RemoteProcessParser.parse(
            "42 root 12.5 1.2 bash bash --login\n" +
                "bad row\n" +
                "7 user 0.0 0.1 launchd"
        )

        #expect(processes.count == 2)
        #expect(processes.first?.pid == 42)
        #expect(processes.first?.command == "bash --login")
        #expect(processes.last?.command == "launchd")
    }

    @Test
    func remoteProcessParserParsesTerminationIdentity() {
        let identity = RemoteProcessParser.parseIdentity("root bash bash --login\n")

        #expect(identity?.user == "root")
        #expect(identity?.command == "bash --login")
    }

    @Test
    func remoteToolParsersDecodeServicesAndContainers() {
        let services = RemoteSystemServiceParser.parse(
            "ssh.service loaded active running OpenSSH server\n" +
                "cron.service loaded inactive dead Scheduler"
        )
        let containers = RemoteContainerParser.parse(
            "abc123\tweb\tnginx:latest\tUp 2 hours\n" +
                "def456\tdb\tpostgres\tExited (0) 1 hour ago",
            runtime: "docker"
        )

        #expect(services.count == 2)
        #expect(services.first?.isActive == true)
        #expect(services.first?.description == "OpenSSH server")
        #expect(containers.count == 2)
        #expect(containers.first?.isRunning == true)
        #expect(containers.last?.isRunning == false)
    }

    @Test
    func connectionResultClassificationMatchesTransportFailures() {
        #expect(ConnectionResult.classify(message: "Connection timed out") == .timeout)
        #expect(ConnectionResult.classify(message: "Authentication failed") == .authFailed)
        #expect(ConnectionResult.classify(message: "Connection refused") == .networkError)
        #expect(ConnectionResult.classify(message: "Unexpected failure") == .unknownError)
    }

    @Test
    func connectionStatsStorePersistsAndSummarizesRecords() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConnectionStatsTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("connection-stats.json")
        let store = ConnectionStatsStore(fileURL: fileURL)
        let serverID = UUID()
        let now = Date()

        defer { try? FileManager.default.removeItem(at: directory) }

        try await store.record(
            ConnectionStat(
                serverID: serverID,
                serverName: "Test server",
                timestamp: now.addingTimeInterval(-2),
                result: .success,
                durationMilliseconds: 125
            )
        )
        try await store.record(
            ConnectionStat(
                serverID: serverID,
                serverName: "Test server",
                timestamp: now,
                result: .authFailed,
                errorMessage: "Authentication failed",
                durationMilliseconds: 80
            )
        )

        let summaries = try await store.allServerStats()
        let summary = try #require(summaries.first)
        #expect(summary.totalAttempts == 2)
        #expect(summary.successCount == 1)
        #expect(summary.failureCount == 1)
        #expect(summary.successRate == 0.5)
        #expect(summary.recentConnections.first?.result == .authFailed)

        let reloadedStore = ConnectionStatsStore(fileURL: fileURL)
        let reloaded = try await reloadedStore.allServerStats()
        let reloadedSummary = try #require(reloaded.first)
        #expect(reloadedSummary.serverID == summary.serverID)
        #expect(reloadedSummary.serverName == summary.serverName)
        #expect(reloadedSummary.totalAttempts == summary.totalAttempts)
        #expect(reloadedSummary.successCount == summary.successCount)
        #expect(
            reloadedSummary.records.map { $0.result } == summary.records.map { $0.result }
        )
        #expect(
            abs(
                reloadedSummary.records[0].timestamp.timeIntervalSince(
                    summary.records[0].timestamp
                )
            ) < 0.001
        )
    }

    @Test
    func connectionStatsStoreClearsSingleServerAndReportsDatabaseSize() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConnectionStatsTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("connection-stats.json")
        let store = ConnectionStatsStore(fileURL: fileURL)
        let firstServerID = UUID()
        let secondServerID = UUID()
        let now = Date()

        defer { try? FileManager.default.removeItem(at: directory) }

        for serverID in [firstServerID, secondServerID] {
            try await store.record(
                ConnectionStat(
                    serverID: serverID,
                    serverName: serverID == firstServerID ? "First" : "Second",
                    timestamp: now,
                    result: .success,
                    durationMilliseconds: 10
                )
            )
        }

        let sizeAfterRecord = await store.databaseSize()
        #expect(sizeAfterRecord > 0)

        try await store.clear(serverID: firstServerID)
        let remaining = try await store.allServerStats()
        #expect(remaining.count == 1)
        #expect(remaining.first?.serverID == secondServerID)

        let sizeAfterClear = await store.databaseSize()
        #expect(sizeAfterClear > 0)
    }

    @Test
    func terminalOutputParserRemovesControlSequencesAcrossChunks() {
        var parser = TerminalOutputParser()

        let first = parser.consume("\u{1B}[?2004h\u{1B}[01;32mroot")
        let second = parser.consume("@server\u{1B}[00m:~# \u{1B}[?2004l\n")

        #expect(first + second == "root@server:~# \n")
    }

    @Test
    func sftpTransferProgressCalculatesFractionAndHandlesUnknownSize() {
        #expect(
            SFTPTransferProgress(transferredBytes: 25, totalBytes: 100).fractionCompleted == 0.25
        )
        #expect(
            SFTPTransferProgress(transferredBytes: 8, totalBytes: nil).fractionCompleted == nil
        )
        #expect(
            SFTPTransferProgress(transferredBytes: 0, totalBytes: 0).fractionCompleted == 1
        )
    }

    @Test
    func sftpTransferUsesRemoteFileNameForMissionDisplay() {
        let transfer = SFTPTransfer(
            id: UUID(),
            serverID: UUID(),
            serverName: "Test server",
            remotePath: "/var/log/server.log",
            localURL: FileManager.default.temporaryDirectory.appendingPathComponent("server.log"),
            direction: .download,
            createdAt: Date(),
            totalBytes: 10,
            transferredBytes: 5,
            state: .downloading,
            errorMessage: nil,
            finishedAt: nil
        )

        #expect(transfer.fileName == "server.log")
        #expect(transfer.progress == 0.5)
    }

    @Test
    func pveResourcePayloadDecodesAndCalculatesUsage() throws {
        let resources = try JSONDecoder().decode(
            [PVEResource].self,
            from: Data(
                """
                [{"id":"qemu/100","type":"qemu","node":"pve","vmid":100,"name":"router","status":"running","cpu":2,"maxcpu":4,"mem":512,"maxmem":1024,"disk":2048,"maxdisk":4096}]
                """.utf8
            )
        )
        let resource = try #require(resources.first)

        #expect(resource.id == "qemu:pve:qemu/100")
        #expect(resource.displayName == "router")
        #expect(resource.isRunning)
        #expect(resource.memoryFraction == 0.5)
        #expect(resource.diskFraction == 0.5)
    }

    @Test
    func pveResourceDecodesOptionalIOUptimeAndStorageFields() throws {
        let resources = try JSONDecoder().decode(
            [PVEResource].self,
            from: Data(
                """
                [
                  {"id":"node/pve","type":"node","node":"pve","status":"online","cpu":0.25,"maxcpu":4,"mem":2048,"maxmem":4096,"uptime":90061},
                  {"id":"qemu/100","type":"qemu","node":"pve","vmid":100,"name":"router","status":"running","uptime":3600,"netin":1024,"netout":512,"diskread":2048,"diskwrite":4096},
                  {"id":"storage/local","type":"storage","storage":"local","node":"pve","status":"available","plugintype":"dir","content":"iso,vztmpl","disk":100,"maxdisk":1000}
                ]
                """.utf8
            )
        )
        let node = try #require(resources.first { $0.type == "node" })
        let vm = try #require(resources.first { $0.type == "qemu" })
        let storage = try #require(resources.first { $0.type == "storage" })

        #expect(node.uptime == 90_061)
        #expect(node.isOnline)
        #expect(!node.isRunning)

        #expect(vm.uptime == 3_600)
        #expect(vm.networkInBytes == 1_024)
        #expect(vm.networkOutBytes == 512)
        #expect(vm.diskReadBytes == 2_048)
        #expect(vm.diskWriteBytes == 4_096)

        #expect(storage.pluginType == "dir")
        #expect(storage.content == "iso,vztmpl")
        #expect(storage.isOnline)
    }

    @Test
    func pveResourceDecodesWithoutOptionalFields() throws {
        let resources = try JSONDecoder().decode(
            [PVEResource].self,
            from: Data(
                """
                [{"id":"qemu/101","type":"qemu","node":"pve","vmid":101,"name":"test","status":"stopped"}]
                """.utf8
            )
        )
        let resource = try #require(resources.first)

        #expect(resource.uptime == nil)
        #expect(resource.networkInBytes == nil)
        #expect(resource.networkOutBytes == nil)
        #expect(resource.diskReadBytes == nil)
        #expect(resource.diskWriteBytes == nil)
        #expect(resource.pluginType == nil)
        #expect(resource.content == nil)
        #expect(!resource.isRunning)
        #expect(!resource.isOnline)
    }

    @Test
    func portForwardConfigurationValidatesLocalRemoteAndDynamicModes() throws {
        let serverID = UUID()
        let local = PortForwardConfiguration(
            serverID: serverID,
            name: "Web",
            type: .local,
            localPort: 8080,
            remoteHost: "127.0.0.1",
            remotePort: 80
        )
        try local.validate()
        #expect(local.displayAddress == "localhost:8080 -> 127.0.0.1:80")

        let dynamic = PortForwardConfiguration(
            serverID: serverID,
            name: "SOCKS",
            type: .dynamic,
            localPort: 1080
        )
        try dynamic.validate()
        #expect(dynamic.displayAddress == "localhost:1080 (SOCKS5)")

        let invalid = PortForwardConfiguration(
            serverID: serverID,
            name: "Invalid",
            type: .remote,
            localPort: 8080
        )
        #expect(throws: PortForwardConfigurationError.self) {
            try invalid.validate()
        }
    }

    @Test
    func portForwardStorePersistsRulesPerServer() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PortForwardTests-\(UUID().uuidString)", isDirectory: true)
        let store = PortForwardStore(
            fileURL: directory.appendingPathComponent("port-forwards.json")
        )
        let firstServerID = UUID()
        let secondServerID = UUID()
        let configuration = PortForwardConfiguration(
            serverID: firstServerID,
            name: "Web",
            type: .local,
            localPort: 8080,
            remoteHost: "localhost",
            remotePort: 80
        )

        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.upsert(configuration)
        try await store.upsert(
            PortForwardConfiguration(
                serverID: secondServerID,
                name: "Other",
                type: .dynamic,
                localPort: 1080
            )
        )

        let firstRules = try await store.configurations(for: firstServerID)
        let secondRules = try await store.configurations(for: secondServerID)
        #expect(firstRules == [configuration])
        #expect(secondRules.count == 1)

        try await store.remove(id: configuration.id)
        let remainingRules = try await store.configurations(for: firstServerID)
        #expect(remainingRules.isEmpty)
    }
}
