import Foundation

actor SnippetStore {
    static let live = SnippetStore()

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            self.fileURL = applicationSupport
                .appendingPathComponent("ServerBox", isDirectory: true)
                .appendingPathComponent("snippets.json")
        }
    }

    func load() throws -> [NativeSnippet] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try decoder.decode([NativeSnippet].self, from: data)
        } catch {
            throw SnippetError.invalidData
        }
    }

    func save(_ snippets: [NativeSnippet]) throws {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snippets).write(to: fileURL, options: .atomic)
        } catch {
            throw SnippetError.writeFailed
        }
    }
}
