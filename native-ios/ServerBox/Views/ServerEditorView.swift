import SwiftUI

struct ServerEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var urlText: String
    @State private var validationMessage: String?

    private let existingServer: MonitorServer?
    private let onSave: (MonitorServer) -> Void

    init(
        server: MonitorServer? = nil,
        onSave: @escaping (MonitorServer) -> Void
    ) {
        existingServer = server
        self.onSave = onSave
        _name = State(initialValue: server?.name ?? "")
        _urlText = State(initialValue: server?.statusURL.absoluteString ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Display name", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("https://example.com/status", text: $urlText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Monitor endpoint")
                } footer: {
                    Text("A root URL automatically receives the /status path.")
                }

                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(existingServer == nil ? "Add server" : "Edit server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            validationMessage = "Enter a name for this server."
            return
        }

        do {
            let url = try MonitorEndpoint.normalizedURL(from: urlText)
            let server = MonitorServer(
                id: existingServer?.id ?? UUID(),
                name: trimmedName,
                statusURL: url,
                isEnabled: existingServer?.isEnabled ?? true,
                createdAt: existingServer?.createdAt ?? Date()
            )
            onSave(server)
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
        }
    }
}
