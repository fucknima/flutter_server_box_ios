import Foundation

enum SnippetFormat {
    enum Segment: Equatable, Sendable {
        case text(String)
        case control(character: Character, alt: Bool)
        case sleep(seconds: Int)
        case enter(times: Int)
    }

    static func parse(_ script: String) -> [Segment] {
        var segments: [Segment] = []
        var buffer = ""
        var index = script.startIndex

        func flushText() {
            if !buffer.isEmpty {
                segments.append(.text(buffer))
                buffer = ""
            }
        }

        while index < script.endIndex {
            guard script[index] == "$",
                  script[index..<script.endIndex].hasPrefix("${"),
                  let closeIndex = script[index...].firstIndex(of: "}") else {
                buffer.append(script[index])
                index = script.index(after: index)
                continue
            }
            let markerEnd = script.index(after: closeIndex)
            let marker = String(script[index..<markerEnd])
            let inner = String(script[script.index(index, offsetBy: 2)..<closeIndex])

            switch Self.segment(for: marker, inner: inner) {
            case .some(let segment):
                flushText()
                segments.append(segment)
            case .none:
                buffer.append(marker)
            }
            index = markerEnd
        }
        flushText()
        return segments
    }

    private static func segment(for marker: String, inner: String) -> Segment? {
        let lower = inner.lowercased()
        if lower.hasPrefix("ctrl+") {
            guard let first = lower.dropFirst("ctrl+".count).first else { return nil }
            return .control(character: first, alt: false)
        }
        if lower.hasPrefix("alt+") {
            guard let first = lower.dropFirst("alt+".count).first else { return nil }
            return .control(character: first, alt: true)
        }
        if lower.hasPrefix("sleep ") {
            guard let seconds = Int(lower.dropFirst("sleep ".count)) else { return nil }
            return .sleep(seconds: seconds)
        }
        if lower.hasPrefix("enter") {
            let countText = String(lower.dropFirst("enter".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let times = countText.isEmpty ? 1 : (Int(countText) ?? 1)
            return .enter(times: max(1, times))
        }
        return nil
    }

    static func replaceVariables(
        _ script: String,
        host: String,
        port: Int,
        username: String,
        serverID: UUID,
        name: String,
        password: String = ""
    ) -> String {
        let replacements: [String: String] = [
            "${host}": host,
            "${port}": String(port),
            "${user}": username,
            "${pwd}": password,
            "${id}": serverID.uuidString,
            "${name}": name,
        ]
        var result = script
        for (key, value) in replacements {
            result = result.replacingOccurrences(of: key, with: value)
        }
        return result
    }

    static func controlString(character: Character, alt: Bool) -> String {
        guard let scalar = character.unicodeScalars.first else { return "" }
        if alt {
            return "\u{1B}\(character)"
        }
        if character.isLetter {
            let value = scalar.value
            let controlCode = value >= 97 && value <= 122 ? value - 96 : value
            if let unicodeScalar = UnicodeScalar(controlCode) {
                return String(unicodeScalar)
            }
        }
        return String(character)
    }

    static func execute(
        _ script: String,
        server: ServerConfiguration,
        password: String,
        send: (String) async throws -> Void,
        sleep: (TimeInterval) async throws -> Void
    ) async throws {
        let replaced = replaceVariables(
            script,
            host: server.host,
            port: server.port,
            username: server.username,
            serverID: server.id,
            name: server.name,
            password: password
        )
        for segment in parse(replaced) {
            switch segment {
            case .text(let text):
                try await send(text)
            case .control(let character, let alt):
                try await send(Self.controlString(character: character, alt: alt))
            case .sleep(let seconds):
                try await sleep(TimeInterval(seconds))
            case .enter(let times):
                try await send(String(repeating: "\n", count: times))
            }
        }
    }
}
