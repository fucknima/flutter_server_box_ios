import Foundation

struct PVEResource: Codable, Equatable, Identifiable, Sendable {
    let type: String
    let node: String
    let resourceID: String?
    let storage: String?
    let vmid: Int?
    let name: String?
    let status: String?
    let cpu: Double?
    let maxCPU: Double?
    let memoryBytes: UInt64?
    let maxMemoryBytes: UInt64?
    let diskBytes: UInt64?
    let maxDiskBytes: UInt64?
    let networkInBytes: UInt64?
    let networkOutBytes: UInt64?
    let uptime: Int?
    let diskReadBytes: UInt64?
    let diskWriteBytes: UInt64?
    let pluginType: String?
    let content: String?

    var id: String {
        "\(type):\(node):\(resourceID ?? vmid.map(String.init) ?? storage ?? "node")"
    }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        if let storage, !storage.isEmpty { return storage }
        if let vmid { return "\(type.uppercased()) \(vmid)" }
        return node
    }

    var isRunning: Bool {
        status?.lowercased() == "running"
    }

    var isOnline: Bool {
        switch status?.lowercased() {
        case "running", "online", "available", "ok":
            return true
        default:
            return false
        }
    }

    var memoryFraction: Double? {
        guard let memoryBytes, let maxMemoryBytes, maxMemoryBytes > 0 else { return nil }
        return min(1, Double(memoryBytes) / Double(maxMemoryBytes))
    }

    var diskFraction: Double? {
        guard let diskBytes, let maxDiskBytes, maxDiskBytes > 0 else { return nil }
        return min(1, Double(diskBytes) / Double(maxDiskBytes))
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case node
        case resourceID = "id"
        case storage
        case vmid
        case name
        case status
        case cpu
        case maxCPU = "maxcpu"
        case memoryBytes = "mem"
        case maxMemoryBytes = "maxmem"
        case diskBytes = "disk"
        case maxDiskBytes = "maxdisk"
        case networkInBytes = "netin"
        case networkOutBytes = "netout"
        case uptime
        case diskReadBytes = "diskread"
        case diskWriteBytes = "diskwrite"
        case pluginType = "plugintype"
        case content
    }
}

enum PVEAction: String, CaseIterable, Sendable {
    case start
    case stop
    case reboot
    case shutdown
}
