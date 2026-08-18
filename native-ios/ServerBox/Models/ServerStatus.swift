import Foundation

struct ServerStatus: Codable, Equatable, Sendable {
    var name: String
    var cpu: String
    var memory: String
    var disk: String
    var network: String
    var dist: String
    var customCmds: [String: String]
    var cpuCores: [Double]
    var cpuBrand: String
    var disks: [DiskMetric]
    var temps: [String: Double]
    var uptime: String
    var swap: String
    var sysName: String

    enum CodingKeys: String, CodingKey {
        case name
        case cpu
        case memory = "mem"
        case disk
        case network = "net"
        case dist
        case customCmds
        case cpuCores
        case cpuBrand
        case disks
        case temps
        case uptime
        case swap
        case sysName
    }

    init(
        name: String,
        cpu: String,
        memory: String,
        disk: String,
        network: String,
        dist: String = "",
        customCmds: [String: String] = [:],
        cpuCores: [Double] = [],
        cpuBrand: String = "",
        disks: [DiskMetric] = [],
        temps: [String: Double] = [:],
        uptime: String = "",
        swap: String = "",
        sysName: String = ""
    ) {
        self.name = name
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
        self.network = network
        self.dist = dist
        self.customCmds = customCmds
        self.cpuCores = cpuCores
        self.cpuBrand = cpuBrand
        self.disks = disks
        self.temps = temps
        self.uptime = uptime
        self.swap = swap
        self.sysName = sysName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = container.decodeFlexibleString(forKey: .name)
        cpu = container.decodeFlexibleString(forKey: .cpu)
        memory = container.decodeFlexibleString(forKey: .memory)
        disk = container.decodeFlexibleString(forKey: .disk)
        network = container.decodeFlexibleString(forKey: .network)
        dist = container.decodeFlexibleString(forKey: .dist)
        customCmds = (try? container.decode([String: String].self, forKey: .customCmds)) ?? [:]
        cpuCores = (try? container.decode([Double].self, forKey: .cpuCores)) ?? []
        cpuBrand = container.decodeFlexibleString(forKey: .cpuBrand)
        disks = (try? container.decode([DiskMetric].self, forKey: .disks)) ?? []
        temps = (try? container.decode([String: Double].self, forKey: .temps)) ?? [:]
        uptime = container.decodeFlexibleString(forKey: .uptime)
        swap = container.decodeFlexibleString(forKey: .swap)
        sysName = container.decodeFlexibleString(forKey: .sysName)
    }

    var cpuFraction: Double? {
        Self.percentFraction(cpu)
    }

    var memoryFraction: Double? {
        Self.ratioFraction(memory)
    }

    var diskFraction: Double? {
        Self.ratioFraction(disk)
    }

    var swapFraction: Double? {
        Self.ratioFraction(swap)
    }

    private static func percentFraction(_ value: String) -> Double? {
        let number = value
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Double(number.replacingOccurrences(of: ",", with: ".")) else {
            return nil
        }
        let fraction = parsed > 1 ? parsed / 100 : parsed
        return min(max(fraction, 0), 1)
    }

    private static func ratioFraction(_ value: String) -> Double? {
        let parts = value.components(separatedBy: "/")
        guard parts.count >= 2,
              let used = parseQuantity(parts[0]),
              let total = parseQuantity(parts[1]),
              total > 0 else {
            return nil
        }
        return min(max(used / total, 0), 1)
    }

    private static func parseQuantity(_ value: String) -> Double? {
        let tokens = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let first = tokens.first else {
            return nil
        }

        let numericPrefix = first.prefix {
            $0.isNumber || $0 == "." || $0 == ","
        }
        guard !numericPrefix.isEmpty,
              let number = Double(
                String(numericPrefix).replacingOccurrences(of: ",", with: ".")
              ) else {
            return nil
        }

        let suffix = String(first.dropFirst(numericPrefix.count)).lowercased()
        let unit = suffix.isEmpty && tokens.count > 1
            ? String(tokens[1]).lowercased()
            : suffix
        let multiplier: Double
        switch unit {
        case "k", "kb", "kib": multiplier = 1024
        case "m", "mb", "mib": multiplier = 1024 * 1024
        case "g", "gb", "gib": multiplier = 1024 * 1024 * 1024
        case "t", "tb", "tib": multiplier = 1024 * 1024 * 1024 * 1024
        case "p", "pb", "pib": multiplier = 1024 * 1024 * 1024 * 1024 * 1024
        default: multiplier = 1
        }
        return number * multiplier
    }
}

struct DiskMetric: Codable, Equatable, Sendable {
    var name: String
    var filesystem: String
    var mountPath: String
    var used: UInt64
    var total: UInt64
    var usedPercent: Double

    init(
        name: String = "",
        filesystem: String = "",
        mountPath: String = "",
        used: UInt64 = 0,
        total: UInt64 = 0,
        usedPercent: Double = 0
    ) {
        self.name = name
        self.filesystem = filesystem
        self.mountPath = mountPath
        self.used = used
        self.total = total
        self.usedPercent = usedPercent
    }

    var available: UInt64 {
        total > used ? total - used : 0
    }
}

struct MonitorStatusEnvelope: Decodable, Sendable {
    let code: Int
    let message: String
    let data: ServerStatus?

    enum CodingKeys: String, CodingKey {
        case code
        case message = "msg"
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = container.decodeFlexibleInt(forKey: .code, default: 1)
        message = container.decodeFlexibleString(forKey: .message)
        data = try container.decodeIfPresent(ServerStatus.self, forKey: .data)
    }
}

enum Dist: String, CaseIterable, Sendable {
    case debian
    case ubuntu
    case centos
    case fedora
    case opensuse
    case kali
    case wrt
    case armbian
    case arch
    case alpine
    case rocky
    case deepin
    case coreelec

    static func detect(from string: String) -> String? {
        let lower = string.lowercased()
        for dist in allCases where lower.contains(dist.rawValue) {
            return dist.rawValue
        }
        if lower.contains("istoreos") {
            return Dist.wrt.rawValue
        }
        return nil
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleString(forKey key: Key) -> String {
        if let value = try? decode(String.self, forKey: key) {
            return value
        }
        if let value = try? decode(Double.self, forKey: key) {
            return String(value)
        }
        if let value = try? decode(Int.self, forKey: key) {
            return String(value)
        }
        return ""
    }

    func decodeFlexibleInt(forKey key: Key, default defaultValue: Int) -> Int {
        if let value = try? decode(Int.self, forKey: key) {
            return value
        }
        if let value = try? decode(String.self, forKey: key),
           let parsed = Int(value) {
            return parsed
        }
        return defaultValue
    }
}
