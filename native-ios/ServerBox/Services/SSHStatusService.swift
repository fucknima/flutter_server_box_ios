import Foundation

final class SSHStatusService: @unchecked Sendable {
    static let live = SSHStatusService()

    private let lock = NSLock()
    private var installedLocations: [UUID: SrvBoxScript.ScriptLocation] = [:]
    private var cpuSamples: [UUID: [UInt64]] = [:]
    private var networkSamples: [UUID: LinuxStatusParser.NetworkSample] = [:]
    private var networkTimes: [UUID: UInt64] = [:]

    init() {}

    func fetchStatus(for server: ServerConfiguration) async throws -> ServerStatus {
        let location = try await ensureScript(for: server)

        do {
            let raw = try await SSHConnectionService.live.execute(
                SrvBoxScript.execCommand("SbStatus", at: location, flag: "s"),
                on: server.id,
                maxResponseSize: 8 * 1024 * 1024
            )
            return try parse(raw, for: server)
        } catch {
            if let transportError = error as? SSHTransportError,
               case .commandFailed = transportError {
                let reinstalled = try await installScript(for: server)
                let raw = try await SSHConnectionService.live.execute(
                    SrvBoxScript.execCommand("SbStatus", at: reinstalled, flag: "s"),
                    on: server.id,
                    maxResponseSize: 8 * 1024 * 1024
                )
                return try parse(raw, for: server)
            }
            throw error
        }
    }

    func resetScript(for server: ServerConfiguration) {
        lock.lock()
        installedLocations.removeValue(forKey: server.id)
        lock.unlock()
    }

    func scriptLocation(for server: ServerConfiguration) async throws -> SrvBoxScript.ScriptLocation {
        try await ensureScript(for: server)
    }

    private func parse(_ raw: String, for server: ServerConfiguration) throws -> ServerStatus {
        let sections = SrvBoxScript.parseScriptOutput(raw)
        guard !sections.isEmpty else {
            throw SSHStatusError.invalidOutput
        }

        var status = LinuxStatusParser.parse(
            sections: sections,
            fallbackName: server.name
        )

        parseCpu(sections, serverID: server.id, into: &status)
        status.network = parseNetwork(sections, serverID: server.id)
        status.customCmds = parseCustomCommands(
            sections,
            names: Array(server.customCommands.keys)
        )
        return status
    }

    private func parseCpu(
        _ sections: [String: String],
        serverID: UUID,
        into status: inout ServerStatus
    ) {
        guard let raw = sections["cpu"] else { return }
        let previous: [UInt64]?
        lock.lock()
        previous = cpuSamples[serverID]
        lock.unlock()

        guard let parsed = LinuxStatusParser.parseCores(raw, previous: previous) else {
            return
        }
        lock.lock()
        cpuSamples[serverID] = parsed.sample
        lock.unlock()
        status.cpu = String(format: "%.1f%%", parsed.overall)
        status.cpuCores = parsed.cores
    }

    private func parseNetwork(_ sections: [String: String], serverID: UUID) -> String {
        guard let raw = sections["net"] else { return "" }
        let time = UInt64(sections["time"] ?? "") ?? 0
        let previous: LinuxStatusParser.NetworkSample?
        let previousTime: UInt64?
        lock.lock()
        previous = networkSamples[serverID]
        previousTime = networkTimes[serverID]
        lock.unlock()

        guard let speed = LinuxStatusParser.parseNetworkSpeed(
            raw,
            previous: previous,
            time: time,
            previousTime: previousTime
        ) else {
            return ""
        }
        lock.lock()
        networkSamples[serverID] = LinuxStatusParser.NetworkSample(
            rx: speed.rxTotal,
            tx: speed.txTotal
        )
        networkTimes[serverID] = time
        lock.unlock()
        return "\(LinuxStatusParser.humanSpeed(speed.rxSpeed)) / \(LinuxStatusParser.humanSpeed(speed.txSpeed))"
    }

    private func parseCustomCommands(
        _ sections: [String: String],
        names: [String]
    ) -> [String: String] {
        var result: [String: String] = [:]
        for name in names {
            let value = sections[SrvBoxScript.customResultKey(name)] ?? ""
            if !value.isEmpty {
                result[name] = value
            }
        }
        return result
    }

    private func ensureScript(for server: ServerConfiguration) async throws -> SrvBoxScript.ScriptLocation {
        lock.lock()
        let installed = installedLocations[server.id]
        lock.unlock()
        if let installed {
            return installed
        }
        return try await installScript(for: server)
    }

    private func installScript(
        for server: ServerConfiguration
    ) async throws -> SrvBoxScript.ScriptLocation {
        let script = SrvBoxScript.buildScript(
            customCmds: server.customCommands,
            disabledCmdTypes: Array(server.disabledStatusTypes)
        )

        let locations: [SrvBoxScript.ScriptLocation] = [.tmp, .home]
        var lastError: Error?
        for location in locations {
            do {
                try await SSHConnectionService.live.writeScriptFile(
                    serverID: server.id,
                    content: script,
                    location: location
                )
                lock.lock()
                installedLocations[server.id] = location
                lock.unlock()
                return location
            } catch {
                lastError = error
            }
        }
        throw lastError ?? SSHStatusError.scriptInstallFailed
    }
}

enum SSHStatusError: LocalizedError, Equatable, Sendable {
    case invalidOutput
    case scriptInstallFailed

    var errorDescription: String? {
        switch self {
        case .invalidOutput:
            return "服务器返回了无法识别的状态数据。"
        case .scriptInstallFailed:
            return "无法在服务器上安装监控脚本。"
        }
    }
}
