import Combine
import Foundation

@MainActor
final class SnippetListViewModel: ObservableObject {
    @Published private(set) var snippets: [NativeSnippet] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let store: SnippetStore
    private var didLoad = false

    init(store: SnippetStore = .live) {
        self.store = store
    }

    var tags: [String] {
        Array(Set(snippets.flatMap(\.tags))).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    func loadIfNeeded() async {
        guard !didLoad else { return }
        didLoad = true
        await load()
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            snippets = try await store.load().sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func save(_ snippet: NativeSnippet) async {
        do {
            let name = snippet.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw SnippetError.emptyName }
            guard !snippet.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SnippetError.emptyScript
            }

            let normalized = NativeSnippet(
                id: snippet.id,
                name: name,
                script: snippet.script,
                note: snippet.note,
                tags: snippet.tags,
                autoRunOn: snippet.autoRunOn,
                createdAt: snippet.createdAt,
                updatedAt: Date()
            )
            if let index = snippets.firstIndex(where: { $0.id == normalized.id }) {
                snippets[index] = normalized
            } else {
                snippets.append(normalized)
            }
            snippets.sort {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            try await store.save(snippets)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ snippet: NativeSnippet) async {
        snippets.removeAll { $0.id == snippet.id }
        do {
            try await store.save(snippets)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
