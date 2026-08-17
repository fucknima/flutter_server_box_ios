import Foundation

struct PrivateKeyRecord: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    var name: String
    let createdAt: Date
}
