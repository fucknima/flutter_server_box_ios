import SwiftUI

struct RawSettingsEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var errorMessage: String?

    init() {
        var values: [String: Any] = [:]
        for key in SettingsStore.editableKeys {
            if let object = UserDefaults.standard.object(forKey: key) {
                values[key] = object
            }
        }
        _text = State(initialValue: Self.jsonText(values))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 300)
                } header: {
                    Text("Raw settings")
                } footer: {
                    Text("Edit the JSON values directly. Wrong values may break behavior; make a backup first. Hidden settings: native.timeOut (seconds, default 5), native.recordHistory (bool, default true), native.textFactor (double, default 1.0).")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Edit raw settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
        .tint(DesignTokens.accent)
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "The JSON cannot be empty."
            return
        }
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            errorMessage = "The input is not a valid JSON object."
            return
        }
        for key in SettingsStore.editableKeys {
            if let value = json[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        dismiss()
    }

    private static func jsonText(_ values: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: values,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
