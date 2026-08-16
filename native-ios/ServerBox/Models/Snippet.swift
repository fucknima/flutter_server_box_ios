import Foundation

struct NativeSnippet: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var script: String
    var note: String
    var tags: [String]
    var autoRunOn: [UUID]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        script: String,
        note: String = "",
        tags: [String] = [],
        autoRunOn: [UUID] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.script = script
        self.note = note
        self.tags = tags
        self.autoRunOn = autoRunOn
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum SnippetError: LocalizedError, Equatable, Sendable {
    case emptyName
    case emptyScript
    case invalidData
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .emptyName:
            "Enter a snippet name."
        case .emptyScript:
            "Enter a command or script."
        case .invalidData:
            "Saved snippets could not be read."
        case .writeFailed:
            "Snippet changes could not be saved."
        }
    }
}
