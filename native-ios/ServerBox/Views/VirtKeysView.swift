import SwiftUI

struct VirtKeysView: View {
    @State private var order: [String] = []
    @State private var disabled: Set<String> = []

    var body: some View {
        List {
            Section {
                ForEach(orderedKeys) { key in
                    HStack(spacing: DesignTokens.spaceS) {
                        Text(key.label)
                            .font(.system(.subheadline, design: .monospaced, weight: .medium))
                            .frame(width: 64, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key.id)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(key.explanation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: enabledBinding(for: key))
                            .labelsHidden()
                    }
                }
                .onMove(perform: move)
            } header: {
                Text("SSH virtual keys")
            } footer: {
                Text("Enable or disable keys and sort them by dragging. Tap a key in the SSH terminal to send its sequence.")
            }
        }
        .navigationTitle("Virtual keys")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .task {
            order = SettingsStore.virtKeyOrder
            disabled = SettingsStore.virtKeyDisabled
        }
    }

    private var orderedKeys: [VirtKeyDefinition] {
        let catalog = VirtKeyCatalog.all
        let ordered = order.compactMap { id in catalog.first { $0.id == id } }
        let missing = catalog.filter { key in !order.contains(key.id) }
        return ordered + missing
    }

    private func enabledBinding(for key: VirtKeyDefinition) -> Binding<Bool> {
        Binding(
            get: { !disabled.contains(key.id) },
            set: { enabled in
                if enabled {
                    disabled.remove(key.id)
                } else {
                    disabled.insert(key.id)
                }
                SettingsStore.virtKeyDisabled = disabled
            }
        )
    }

    private func move(from source: IndexSet, to destination: Int) {
        var items = orderedKeys
        items.move(fromOffsets: source, toOffset: destination)
        order = items.map(\.id)
        SettingsStore.virtKeyOrder = order
    }
}
