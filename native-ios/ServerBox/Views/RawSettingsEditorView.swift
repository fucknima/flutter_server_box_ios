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
                    Text("原始设置")
                } footer: {
                    Text("直接编辑 JSON 值。错误的配置可能导致异常，请先备份。隐藏设置：native.timeOut（秒，默认 5）、native.recordHistory（布尔值，默认 true）、native.textFactor（浮点数，默认 1.0）。")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("编辑原始设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
        }
        .tint(DesignTokens.accent)
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "JSON 不能为空。"
            return
        }
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            errorMessage = "输入不是有效的 JSON 对象。"
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
