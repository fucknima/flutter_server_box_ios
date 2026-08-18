import Foundation

protocol MonitorAPIProtocol: Sendable {
    func fetchStatus(for server: MonitorServer) async throws -> ServerStatus
}

struct MonitorAPI: MonitorAPIProtocol {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchStatus(for server: MonitorServer) async throws -> ServerStatus {
        var request = URLRequest(url: server.statusURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw MonitorError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw MonitorError.httpStatus(httpResponse.statusCode)
            }
            guard !data.isEmpty else {
                throw MonitorError.emptyPayload
            }

            let envelope: MonitorStatusEnvelope
            do {
                envelope = try JSONDecoder().decode(MonitorStatusEnvelope.self, from: data)
            } catch {
                throw MonitorError.invalidPayload
            }

            guard envelope.code == 0 else {
                let message = envelope.message.isEmpty
                    ? "监控返回代码 \(envelope.code)。"
                    : envelope.message
                throw MonitorError.serverMessage(message)
            }
            guard let status = envelope.data else {
                throw MonitorError.invalidPayload
            }
            return status
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MonitorError {
            throw error
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw MonitorError.network(error.localizedDescription)
        }
    }
}

enum MonitorError: LocalizedError, Equatable, Sendable {
    case invalidResponse
    case httpStatus(Int)
    case emptyPayload
    case invalidPayload
    case serverMessage(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "服务器返回了无效的响应。"
        case .httpStatus(let statusCode):
            return "服务器返回 HTTP \(statusCode)。"
        case .emptyPayload, .invalidPayload:
            return "服务器返回了无法读取的状态数据。"
        case .serverMessage(let message), .network(let message):
            return message
        }
    }
}
