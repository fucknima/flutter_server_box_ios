import Foundation

enum ServerStatusState: Equatable, Sendable {
    case idle
    case loading
    case loaded(ServerStatus)
    case failed(String)
}
