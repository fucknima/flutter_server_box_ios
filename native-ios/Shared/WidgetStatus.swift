import Foundation

struct WidgetStatusData: Codable, Sendable {
    let name: String
    let cpu: String
    let memory: String
    let disk: String
    let network: String

    enum CodingKeys: String, CodingKey {
        case name
        case cpu
        case memory = "mem"
        case disk
        case network = "net"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = Self.string(container, forKey: .name)
        cpu = Self.string(container, forKey: .cpu)
        memory = Self.string(container, forKey: .memory)
        disk = Self.string(container, forKey: .disk)
        network = Self.string(container, forKey: .network)
    }

    private static func string(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> String {
        if let value = try? container.decode(String.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(Double.self, forKey: key) {
            return String(value)
        }
        if let value = try? container.decode(Int.self, forKey: key) {
            return String(value)
        }
        return ""
    }
}

struct WidgetStatusEnvelope: Decodable, Sendable {
    let code: Int
    let message: String
    let data: WidgetStatusData?

    enum CodingKeys: String, CodingKey {
        case code
        case message = "msg"
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var codeValue: Int = (try? container.decode(Int.self, forKey: .code)) ?? 1
        if let raw = try? container.decode(String.self, forKey: .code),
           let parsed = Int(raw) {
            codeValue = parsed
        }
        code = codeValue
        message = (try? container.decode(String.self, forKey: .message)) ?? ""
        data = try? container.decode(WidgetStatusData.self, forKey: .data)
    }
}

enum WidgetStatusFetcher {
    static func fetch(url: URL, timeout: TimeInterval = 15) async throws -> WidgetStatusData {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw WidgetFetchError.badResponse
        }
        let envelope = try JSONDecoder().decode(WidgetStatusEnvelope.self, from: data)
        guard let status = envelope.data else {
            throw WidgetFetchError.emptyData(message: envelope.message)
        }
        return status
    }
}

enum WidgetFetchError: LocalizedError, Sendable {
    case badResponse
    case emptyData(message: String)

    var errorDescription: String? {
        switch self {
        case .badResponse:
            return "The server returned an invalid response."
        case .emptyData(let message):
            return message.isEmpty ? "No status data." : message
        }
    }
}
