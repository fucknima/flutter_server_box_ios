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
}
