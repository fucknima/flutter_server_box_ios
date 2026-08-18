import SwiftUI

struct IperfView: View {
    @Environment(\.dismiss) private var dismiss
    let onRun: (String) -> Void
    @State private var host = ""
    @State private var port = "5201"
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("主机", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("端口", text: $port)
                        .keyboardType(.numberPad)
                } header: {
                    Text("iperf 服务器")
                }
            }
            .navigationTitle("iperf")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("运行") { run() }
                }
            }
            .alert(
                "iperf 错误",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "请输入主机和有效端口。")
            }
        }
        .tint(DesignTokens.accent)
    }

    private func run() {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, let port = Int(port), (1...65_535).contains(port) else {
            errorMessage = "请输入主机和有效端口。"
            return
        }
        let escapedHost = host.replacingOccurrences(of: "'", with: "'\\''")
        onRun("iperf -c '\(escapedHost)' -p \(port)")
        dismiss()
    }
}
