import Foundation

struct SSHStatusService: Sendable {
    static let live = SSHStatusService()

    func fetchStatus(for server: ServerConfiguration) async throws -> ServerStatus {
        let raw = try await SSHConnectionService.live.execute(
            SSHStatusProtocol.command(customCommands: server.customCommands),
            on: server.id
        )
        return try SSHStatusProtocol.parse(
            raw,
            fallbackName: server.name,
            customCommandNames: Array(server.customCommands.keys)
        )
    }
}

enum SSHStatusProtocol {
    static let separator = "SrvBoxSep."
    static let dataPrefix = "SrvBoxData."

    private static let commands: [(String, String)] = [
        ("host", "hostname 2>/dev/null || cat /etc/hostname"),        ("cpu", #"""
        case "$(uname -s 2>/dev/null)" in
          Darwin|FreeBSD|OpenBSD|NetBSD)
            top -l 1 2>/dev/null | awk -F'[:,%]' '/CPU usage/ {gsub(/ /,"",$2); print $2 "%"; exit}'
            ;;
          *)
            awk '/^cpu / { total=$2+$3+$4+$5+$6+$7+$8; idle=$5+$6; if (total > 0) printf "%.1f%%", (total-idle)*100/total }' /proc/stat
            ;;
        esac
        """#),
        ("memory", #"""
        case "$(uname -s 2>/dev/null)" in
          Darwin|FreeBSD|OpenBSD|NetBSD)
            top -l 1 2>/dev/null | awk '/PhysMem/ {print $2 " / " $6; exit}'
            ;;
          *)
            awk '/MemTotal:/ {total=$2} /MemAvailable:/ {available=$2} END {if (total > 0) printf "%.1fG / %.1fG", (total-available)/1024/1024, total/1024/1024}' /proc/meminfo
            ;;
        esac
        """#),
        ("disk", "df -h / 2>/dev/null | awk 'NR==2 {print $3 \" / \" $2; exit}'"),
        ("network", #"""
        case "$(uname -s 2>/dev/null)" in
          Darwin|FreeBSD|OpenBSD|NetBSD)
            netstat -ibn 2>/dev/null | awk 'NR>1 && $1 != "Name" {rx += $7; tx += $10} END {printf "%.1fM / %.1fM", rx/1048576, tx/1048576}'
            ;;
          *)
            awk 'NR>2 && $0 ~ /:/ {gsub(":", "", $1); rx += $2; tx += $10} END {printf "%.1fM / %.1fM", rx/1048576, tx/1048576}' /proc/net/dev
            ;;
        esac
        """#),
        ("dist", "cat /etc/*-release 2>/dev/null | grep ^PRETTY_NAME"),
    ]

    static func command(customCommands: [String: String] = [:]) -> String {
        let custom = customCommands.map { (name: $0.key, command: $0.value) }
        return (commands + custom)
            .map { framedCommand(name: $0.0, command: $0.1) }
            .joined(separator: "\n")
    }

    static func parse(
        _ raw: String,
        fallbackName: String,
        customCommandNames: [String] = []
    ) throws -> ServerStatus {
        let sections = parseSections(raw)
        guard !sections.isEmpty else {
            throw SSHStatusError.invalidOutput
        }

        func value(_ name: String) -> String {
            sections[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        return ServerStatus(
            name: value("host").isEmpty ? fallbackName : value("host"),
            cpu: value("cpu"),
            memory: value("memory"),
            disk: value("disk"),
            network: value("network"),
            dist: Dist.detect(from: value("dist")) ?? "",
            customCmds: sections.filter { customCommandNames.contains($0.key) }
        )
    }

    private static func framedCommand(name: String, command: String) -> String {
        let marker = marker(for: name)
        return """
        printf '%s\\n' '\(marker)'
        { \(command); } 2>/dev/null | sed 's/^/\(dataPrefix)/'
        """
    }

    private static func marker(for name: String) -> String {
        let encoded = Data(name.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return "\(separator)b64.\(encoded)"
    }

    private static func parseSections(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        var currentName: String?
        var buffer: [String] = []

        func flush() {
            guard let currentName else { return }
            result[currentName] = buffer.joined(separator: "\n")
            buffer.removeAll(keepingCapacity: true)
        }

        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).hasSuffix("\r")
                ? String(String(rawLine).dropLast())
                : String(rawLine)

            if let name = parseMarker(line) {
                flush()
                currentName = name
            } else if currentName != nil {
                if line.hasPrefix(dataPrefix) {
                    buffer.append(String(line.dropFirst(dataPrefix.count)))
                } else {
                    buffer.append(line)
                }
            }
        }
        flush()
        return result
    }

    private static func parseMarker(_ line: String) -> String? {
        guard line.hasPrefix("\(separator)b64.") else { return nil }
        var encoded = String(line.dropFirst("\(separator)b64.".count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - encoded.count % 4) % 4
        encoded += String(repeating: "=", count: padding)
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum SSHStatusError: LocalizedError, Equatable, Sendable {
    case invalidOutput

    var errorDescription: String? {
        "The server returned an unreadable SSH status response."
    }
}
