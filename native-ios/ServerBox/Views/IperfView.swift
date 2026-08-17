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
                    TextField("Host", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                } header: {
                    Text("iperf server")
                }
            }
            .navigationTitle("iperf")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Run") { run() }
                }
            }
            .alert(
                "iperf error",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Enter a host and a valid port.")
            }
        }
        .tint(DesignTokens.accent)
    }

    private func run() {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, let port = Int(port), (1...65_535).contains(port) else {
            errorMessage = "Enter a host and a valid port."
            return
        }
        let escapedHost = host.replacingOccurrences(of: "'", with: "'\\''")
        onRun("iperf -c '\(escapedHost)' -p \(port)")
        dismiss()
    }
}
