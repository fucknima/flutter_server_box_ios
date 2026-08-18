import Foundation

enum LinuxStatusParser {
    static let cpuKey = "linux.cpu"
    static let memKey = "linux.mem"
    static let diskKey = "linux.disk"
    static let netKey = "linux.net"
    static let timeKey = "linux.time"
    static let sysKey = "linux.sys"
    static let hostKey = "linux.host"
    static let uptimeKey = "linux.uptime"
    static let tempTypeKey = "linux.tempType"
    static let tempValKey = "linux.tempVal"

    static func parse(
        sections: [String: String],
        fallbackName: String
    ) -> ServerStatus {
        var status = ServerStatus(
            name: fallbackName,
            cpu: "",
            memory: "",
            disk: "",
            network: ""
        )
        status.sysName = sections[sysKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        status.dist = Dist.detect(from: status.sysName) ?? ""
        let hostname = sections[hostKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !hostname.isEmpty {
            status.name = hostname
        }
        status.uptime = parseUptime(sections[uptimeKey])
        parseTemps(sections, into: &status)
        parseMemory(sections, into: &status)
        parseDisks(sections, into: &status)
        return status
    }

    static func parseCores(
        _ raw: String,
        previous: [UInt64]?
    ) -> (cores: [Double], overall: Double, sample: [UInt64])? {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return nil }
        let firstFields = first.split(separator: " ")
        guard firstFields.count >= 5, String(firstFields[0]).hasPrefix("cpu") else {
            return nil
        }

        var current: [UInt64] = []
        for line in lines {
            let fields = line.split(separator: " ")
            guard fields.count >= 5 else { continue }
            current.append(Self.coreTotal(fields))
        }
        guard !current.isEmpty else { return nil }

        let cores: [Double]
        if let previous, previous.count == current.count {
            cores = (0..<current.count).map { index in
                let delta = current[index] - previous[index]
                let coreFields = lines[index].split(separator: " ")
                let idleNow = Self.coreIdle(coreFields)
                let idleDelta = idleNow > previous[index] ? idleNow - previous[index] : 0
                guard delta > 0 else { return 0 }
                let used = Double(delta - idleDelta) / Double(delta) * 100
                return min(max(used, 0), 100)
            }
        } else {
            cores = Array(repeating: 0, count: current.count)
        }

        let overall = cores.first ?? 0
        let perCore = cores.count > 1 ? Array(cores.dropFirst()) : []
        return (cores: perCore, overall: overall, sample: current)
    }

    private static func coreTotal(_ fields: [Substring]) -> UInt64 {
        guard fields.count >= 8 else { return 0 }
        var total: UInt64 = 0
        for field in fields.dropFirst(1).prefix(8) {
            total += UInt64(field) ?? 0
        }
        return total
    }

    private static func coreIdle(_ fields: [Substring]) -> UInt64 {
        guard fields.count >= 5 else { return 0 }
        return (UInt64(fields[4]) ?? 0) + (fields.count > 5 ? (UInt64(fields[5]) ?? 0) : 0)
    }

    static func parseMemory(
        _ raw: String,
        previous: UInt64? = nil,
        deltaSeconds: Double? = nil
    ) -> (used: UInt64, total: UInt64, swapUsed: UInt64, swapTotal: UInt64)? {
        var memTotal: UInt64 = 0
        var memAvailable: UInt64 = 0
        var swapTotal: UInt64 = 0
        var swapFree: UInt64 = 0
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let parts = line.split(separator: ":")
            guard parts.count >= 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].split(separator: " ").first
            let amount = value.flatMap { UInt64($0) } ?? 0
            switch key {
            case "MemTotal": memTotal = amount
            case "MemAvailable": memAvailable = amount
            case "SwapTotal": swapTotal = amount
            case "SwapFree": swapFree = amount
            default: break
            }
        }
        guard memTotal > 0 else { return nil }
        let used = memAvailable > 0 && memAvailable <= memTotal
            ? memTotal - memAvailable
            : memTotal
        return (
            used: used * 1024,
            total: memTotal * 1024,
            swapUsed: swapTotal > swapFree ? (swapTotal - swapFree) * 1024 : 0,
            swapTotal: swapTotal * 1024
        )
    }

    static func parseNetworkSpeed(
        _ raw: String,
        previous: NetworkSample?,
        time: UInt64,
        previousTime: UInt64?
    ) -> (rxSpeed: UInt64, txSpeed: UInt64, rxTotal: UInt64, txTotal: UInt64)? {
        var rx: UInt64 = 0
        var tx: UInt64 = 0
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let iface = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            if iface == "lo" || iface.hasPrefix("docker") || iface.hasPrefix("veth") {
                continue
            }
            let fields = line[line.index(after: colon)...]
                .split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 9 else { continue }
            rx += UInt64(fields[0]) ?? 0
            tx += UInt64(fields[8]) ?? 0
        }
        guard let previous, let previousTime, time > previousTime else {
            return (rxSpeed: 0, txSpeed: 0, rxTotal: rx, txTotal: tx)
        }
        let seconds = Double(time - previousTime)
        guard seconds > 0 else { return (rxSpeed: 0, txSpeed: 0, rxTotal: rx, txTotal: tx) }
        let rxSpeed = rx >= previous.rx ? UInt64(Double(rx - previous.rx) / seconds) : 0
        let txSpeed = tx >= previous.tx ? UInt64(Double(tx - previous.tx) / seconds) : 0
        return (rxSpeed: rxSpeed, txSpeed: txSpeed, rxTotal: rx, txTotal: tx)
    }

    struct NetworkSample {
        let rx: UInt64
        let tx: UInt64
    }

    static func parseUptime(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        let parts = raw.split(separator: " ")
        guard parts.count >= 2 else { return "" }
        guard parts[1].hasPrefix("up") else { return "" }
        let rest = parts.dropFirst(2).joined(separator: " ")
        guard let comma = rest.firstIndex(of: ",") else { return "" }
        let uptime = rest[..<comma]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if uptime.hasPrefix("1 day") || uptime.hasPrefix("1 hour") {
            return uptime
        }
        return uptime
    }

    static func parseTemps(_ sections: [String: String], into status: inout ServerStatus) {
        guard let typeRaw = sections[tempTypeKey],
              let valueRaw = sections[tempValKey] else { return }
        let types = typeRaw.split(separator: "\n", omittingEmptySubsequences: false)
        let values = valueRaw.split(separator: "\n", omittingEmptySubsequences: false)
        var result: [String: Double] = [:]
        for index in 0..<min(types.count, values.count) {
            let type = types[index].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = values[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !type.isEmpty, !value.isEmpty, let temp = Double(value) else { continue }
            let name = type.split(separator: "/").last.map(String.init) ?? type
            result[name] = temp / 1000
        }
        status.temps = result
    }

    static func parseDisks(_ sections: [String: String], into status: inout ServerStatus) {
        let raw = sections[diskKey] ?? ""
        if raw.contains("LSBLK_SUCCESS") {
            status.disks = parseLSBLK(raw)
        } else if !raw.isEmpty {
            status.disks = parseDf(raw)
        }
        if status.disks.isEmpty { return }

        var used: UInt64 = 0
        var total: UInt64 = 0
        var physicalUsed: UInt64 = 0
        var physicalTotal: UInt64 = 0
        for disk in status.disks {
            used += disk.used
            total += disk.total
            if disk.filesystem.hasPrefix("/dev") {
                physicalUsed += disk.used
                physicalTotal += disk.total
            }
        }
        let summaryUsed = physicalTotal > 0 ? physicalUsed : used
        let summaryTotal = physicalTotal > 0 ? physicalTotal : total
        status.disk = summaryTotal > 0
            ? "\(Self.humanBytes(summaryUsed)) / \(Self.humanBytes(summaryTotal))"
            : ""
    }

    private static func parseLSBLK(_ raw: String) -> [DiskMetric] {
        guard let start = raw.firstIndex(of: "["),
              let end = raw.lastIndex(of: "]") else { return [] }
        let jsonText = String(raw[start...end])
        guard let data = jsonText.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        var result: [DiskMetric] = []
        for item in items {
            let fs = item["fstype"] as? String ?? ""
            let mount = item["mountpoint"] as? String ?? ""
            let name = item["name"] as? String ?? ""
            guard !fs.isEmpty, !mount.isEmpty, !name.isEmpty else { continue }
            let total = (item["fssize"] as? NSNumber)?.uint64Value ?? 0
            let used = (item["fsused"] as? NSNumber)?.uint64Value ?? 0
            let percent = (item["fsuse%"] as? NSNumber)?.doubleValue ?? 0
            guard total > 0 else { continue }
            result.append(
                DiskMetric(
                    name: name,
                    filesystem: fs,
                    mountPath: mount,
                    used: used,
                    total: total,
                    usedPercent: percent
                )
            )
        }
        return result
    }

    private static func parseDf(_ raw: String) -> [DiskMetric] {
        var result: [DiskMetric] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 6 else { continue }
            let percentText = fields[4].trimmingCharacters(in: CharacterSet(charactersIn: "%"))
            guard let percent = Double(percentText) else { continue }
            let blocks = (UInt64(fields[1]) ?? 0) * 1024
            let used = (UInt64(fields[2]) ?? 0) * 1024
            let mount = String(fields[5])
            guard blocks > 0 else { continue }
            result.append(
                DiskMetric(
                    name: String(fields[0]),
                    filesystem: String(fields[0]),
                    mountPath: mount,
                    used: used,
                    total: blocks,
                    usedPercent: percent
                )
            )
        }
        return result
    }

    static func humanBytes(_ value: UInt64) -> String {
        let units = ["B", "K", "M", "G", "T", "P"]
        var amount = Double(value)
        var unitIndex = 0
        while amount >= 1024, unitIndex < units.count - 1 {
            amount /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(Int(amount))\(units[unitIndex])"
        }
        return String(format: "%.1f%@", amount, units[unitIndex])
    }

    static func humanSpeed(_ value: UInt64) -> String {
        humanBytes(value) + "/s"
    }

    private static func parseMemory(_ sections: [String: String], into status: inout ServerStatus) {
        guard let raw = sections[memKey],
              let mem = parseMemory(raw) else { return }
        status.memory = "\(humanBytes(mem.used)) / \(humanBytes(mem.total))"
        if mem.swapTotal > 0 {
            status.swap = "\(humanBytes(mem.swapUsed)) / \(humanBytes(mem.swapTotal))"
        }
    }
}
