import Darwin
import Foundation
import Network

struct SSHDiscoveredHost: Identifiable, Hashable, Sendable {
    let host: String
    let port: Int
    let banner: String?

    var id: String { "\(host):\(port)" }
}

struct SSHDiscoveryReport: Sendable {
    let generatedAt: Date
    let durationMs: Int
    let items: [SSHDiscoveredHost]

    var count: Int { items.count }
}

struct SSHDiscoveryConfig: Sendable {
    var timeoutMs: Int
    var maxConcurrency: Int
    var enableMdns: Bool

    static let `default` = SSHDiscoveryConfig(
        timeoutMs: 700,
        maxConcurrency: 128,
        enableMdns: false
    )
}

struct IPSubnet: Hashable, Sendable {
    let network: String
    let prefix: Int

    var cidrDescription: String { "\(network)/\(prefix)" }

    func enumerateHosts(limit: Int) -> [String] {
        guard let networkValue = SSHDiscoveryService.ipv4ToInt(network) else { return [] }
        let mask: UInt32 = prefix == 0 ? 0 : UInt32(0xffff_ffff) << (32 - prefix)
        let broadcast = networkValue | ~mask
        let lastHost = min(broadcast &- 1, networkValue &+ UInt32(max(limit, 0)))
        guard lastHost > networkValue else { return [] }
        var hosts: [String] = []
        hosts.reserveCapacity(Int(lastHost - networkValue))
        for value in (networkValue + 1)...lastHost {
            hosts.append(SSHDiscoveryService.intToIPv4(value))
        }
        return hosts
    }
}

enum SSHDiscoveryService {
    static let sshServiceType = "_ssh._tcp"
    static let hostEnumerationLimit = 4096

    static func localSubnets() -> [IPSubnet] {
        var ifaddrsPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrsPointer) == 0, let first = ifaddrsPointer else { return [] }
        defer { freeifaddrs(ifaddrsPointer) }

        var result: [IPSubnet] = []
        var seen = Set<String>()
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = pointer {
            defer { pointer = entry.pointee.ifa_next }
            if entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) != 0 { continue }
            guard let addr = entry.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  let mask = entry.pointee.ifa_netmask,
                  mask.pointee.sa_family == UInt8(AF_INET) else { continue }

            let sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            let sinMask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            let hostValue = sin.sin_addr.s_addr.bigEndian
            let maskValue = sinMask.sin_addr.s_addr.bigEndian
            let prefix = leadingOneCount(maskValue)
            guard (24...30).contains(prefix) else { continue }

            let networkValue = hostValue & maskValue
            let firstOctet = networkValue >> 24 & 0xff
            let secondOctet = networkValue >> 16 & 0xff
            guard firstOctet != 127,
                  !(firstOctet == 169 && secondOctet == 254),
                  firstOctet < 224 else { continue }

            let subnet = IPSubnet(network: intToIPv4(networkValue), prefix: prefix)
            if seen.insert(subnet.cidrDescription).inserted {
                result.append(subnet)
            }
        }
        result.sort {
            (ipv4ToInt($0.network) ?? 0) < (ipv4ToInt($1.network) ?? 0)
        }
        return result
    }

    static func scanHosts(
        _ hosts: [String],
        port: Int,
        timeoutMs: Int,
        maxConcurrency: Int
    ) async -> [SSHDiscoveredHost] {
        guard !hosts.isEmpty else { return [] }
        let semaphore = AsyncSemaphore(permits: max(maxConcurrency, 1))
        var results: [SSHDiscoveredHost] = []
        await withTaskGroup(of: SSHDiscoveredHost?.self) { group in
            for host in hosts {
                guard !Task.isCancelled else { break }
                group.addTask {
                    await semaphore.wait()
                    let result = await SSHDiscoveryService.probe(
                        host: host,
                        port: port,
                        timeoutMs: timeoutMs
                    )
                    await semaphore.signal()
                    return result
                }
            }
            for await result in group {
                if let result { results.append(result) }
            }
        }
        return results
    }

    static func mdnsSSHHosts(timeout: TimeInterval = 2.5) async -> [SSHDiscoveredHost] {
        let browser = NWBrowser(
            for: .bonjour(type: sshServiceType, domain: nil),
            using: .tcp
        )
        var endpoints: [NWEndpoint] = []
        var seen = Set<String>()
        let lock = NSLock()

        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                let key = result.endpoint.debugDescription
                lock.lock()
                let isNew = seen.insert(key).inserted
                if isNew { endpoints.append(result.endpoint) }
                lock.unlock()
            }
        }
        browser.start(queue: .global(qos: .userInitiated))
        defer { browser.cancel() }

        do {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        } catch {
            return []
        }

        let captured: [NWEndpoint]
        lock.lock()
        captured = endpoints
        lock.unlock()

        var hosts: [SSHDiscoveredHost] = []
        for endpoint in captured {
            if Task.isCancelled { break }
            if let host = await resolveSSHService(endpoint: endpoint, timeoutMs: 1500) {
                hosts.append(host)
            }
        }
        return hosts
    }

    static func probe(host: String, port: Int, timeoutMs: Int) async -> SSHDiscoveredHost? {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: .tcp
        )
        let timeout = max(timeoutMs, 50)
        return await withCheckedContinuation { continuation in
            let lock = NSLock()
            var finished = false
            var connectTimer: DispatchWorkItem?
            var bannerTimer: DispatchWorkItem?

            func finish(_ result: SSHDiscoveredHost?) {
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                connectTimer?.cancel()
                bannerTimer?.cancel()
                connection.cancel()
                continuation.resume(returning: result)
            }

            connectTimer = DispatchWorkItem { finish(nil) }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + .milliseconds(timeout),
                execute: connectTimer!
            )

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connectTimer?.cancel()
                    bannerTimer = DispatchWorkItem {
                        finish(SSHDiscoveredHost(host: host, port: port, banner: nil))
                    }
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(
                        deadline: .now() + .milliseconds(timeout),
                        execute: bannerTimer!
                    )
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
                        data, _, _, _ in
                        if let data, !data.isEmpty {
                            finish(SSHDiscoveredHost(host: host, port: port, banner: bannerText(from: data)))
                        } else {
                            finish(SSHDiscoveredHost(host: host, port: port, banner: nil))
                        }
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private static func resolveSSHService(
        endpoint: NWEndpoint,
        timeoutMs: Int
    ) async -> SSHDiscoveredHost? {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let timeout = max(timeoutMs, 50)
        let fallbackName = serviceFallbackName(endpoint)
        return await withCheckedContinuation { continuation in
            let lock = NSLock()
            var finished = false
            var connectTimer: DispatchWorkItem?
            var bannerTimer: DispatchWorkItem?

            func finish(_ host: String?, _ port: Int, _ banner: String?) {
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                connectTimer?.cancel()
                bannerTimer?.cancel()
                connection.cancel()
                if let host {
                    continuation.resume(returning: SSHDiscoveredHost(host: host, port: port, banner: banner))
                } else {
                    continuation.resume(returning: nil)
                }
            }

            connectTimer = DispatchWorkItem { finish(nil, 22, nil) }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + .milliseconds(timeout),
                execute: connectTimer!
            )

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connectTimer?.cancel()
                    let resolvedHost = endpointHost(
                        endpoint: connection.currentPath?.remoteEndpoint,
                        fallback: fallbackName
                    )
                    let resolvedPort = endpointPort(connection.currentPath?.remoteEndpoint)
                    bannerTimer = DispatchWorkItem {
                        finish(resolvedHost, resolvedPort, nil)
                    }
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(
                        deadline: .now() + .milliseconds(timeout),
                        execute: bannerTimer!
                    )
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
                        data, _, _, _ in
                        if let data, !data.isEmpty {
                            finish(resolvedHost, resolvedPort, bannerText(from: data))
                        } else {
                            finish(resolvedHost, resolvedPort, nil)
                        }
                    }
                case .failed, .cancelled:
                    finish(nil, 22, nil)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private static func serviceFallbackName(_ endpoint: NWEndpoint) -> String {
        guard case let .service(name, _, domain, _) = endpoint else { return "unknown" }
        let namePart = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let domainPart = domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !namePart.isEmpty else { return "unknown" }
        return domainPart.isEmpty ? namePart : "\(namePart).\(domainPart)"
    }

    private static func endpointHost(endpoint: NWEndpoint?, fallback: String) -> String {
        guard case let .hostPort(host, _)? = endpoint else { return fallback }
        switch host {
        case let .ipv4(address):
            return address.debugDescription
        case let .ipv6(address):
            let text = address.debugDescription.lowercased()
            return text.hasPrefix("fe80") ? fallback : text
        case let .hostname(name):
            return name.isEmpty ? fallback : name
        @unknown default:
            return fallback
        }
    }

    private static func endpointPort(_ endpoint: NWEndpoint?) -> Int {
        guard case let .hostPort(_, port)? = endpoint else { return 22 }
        return Int(port.rawValue)
    }

    private static func bannerText(from data: Data) -> String? {
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        let firstLine = text.split(
            separator: "\n",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func leadingOneCount(_ value: UInt32) -> Int {
        var count = 0
        var current = value
        while current & 0x8000_0000 != 0 {
            count += 1
            current <<= 1
        }
        return count
    }

    static func ipv4ToInt(_ address: String) -> UInt32? {
        let parts = address.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return nil }
        return parts[0] << 24 | parts[1] << 16 | parts[2] << 8 | parts[3]
    }

    static func intToIPv4(_ value: UInt32) -> String {
        "\(value >> 24 & 0xff).\(value >> 16 & 0xff).\(value >> 8 & 0xff).\(value & 0xff)"
    }
}

private actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(permits: Int) {
        self.permits = permits
    }

    func wait() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            permits += 1
        }
    }
}
