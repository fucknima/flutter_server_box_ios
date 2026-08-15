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
}
