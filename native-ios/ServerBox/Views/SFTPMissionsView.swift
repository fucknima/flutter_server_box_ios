import SwiftUI

struct SFTPMissionsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: SFTPTransferViewModel
    let onShowInFiles: (URL) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.transfers.isEmpty {
                    ContentUnavailableView(
                        "No transfer missions",
                        systemImage: "arrow.down.circle",
                        description: Text("SFTP downloads will appear here.")
                    )
                } else {
                    List {
                        ForEach(viewModel.transfers) { transfer in
                            transferRow(transfer)
                        }
                        .onDelete { offsets in
                            let transfers = offsets.map { viewModel.transfers[$0] }
                            for transfer in transfers {
                                viewModel.remove(transfer)
                            }
                        }
                    }
                }
            }
            .navigationTitle("SFTP missions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(DesignTokens.accent)
    }

    private func transferRow(_ transfer: SFTPTransfer) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.spaceS) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(transfer.fileName)
                        .font(.headline)
                        .lineLimit(1)
                    Text(transfer.serverName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                stateIcon(for: transfer.state)
            }

            statusView(for: transfer)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusView(for transfer: SFTPTransfer) -> some View {
        switch transfer.state {
        case .preparing:
            missionSubtitle(transfer.direction == .download ? "Preparing download" : "Preparing upload")
            Button("Cancel", role: .destructive) {
                viewModel.cancel(transfer)
            }
            .font(.caption.weight(.semibold))
        case .downloading, .uploading:
            if let progress = transfer.progress {
                ProgressView(value: progress)
            } else {
                ProgressView()
            }
            HStack {
                Text(transfer.direction == .download ? byteSummary(for: transfer) : "Uploading: \(byteSummary(for: transfer))")
                Spacer()
                Button("Cancel", role: .destructive) {
                    viewModel.cancel(transfer)
                }
                .font(.caption.weight(.semibold))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .finished:
            HStack {
                missionSubtitle(transfer.direction == .download ? "Finished" : "Uploaded")
                Spacer()
                if transfer.direction == .download {
                    Button("Open in Files") {
                        onShowInFiles(transfer.localURL)
                    }
                    .font(.caption.weight(.semibold))
                    ShareLink(item: transfer.localURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share downloaded file")
                }
            }
        case .failed:
            VStack(alignment: .leading, spacing: 4) {
                Text(transfer.errorMessage ?? "Download failed")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Remove") {
                    viewModel.remove(transfer)
                }
                .font(.caption.weight(.semibold))
            }
        case .cancelled:
            HStack {
                missionSubtitle("Cancelled")
                Spacer()
                Button("Remove") {
                    viewModel.remove(transfer)
                }
                .font(.caption.weight(.semibold))
            }
        }
    }

    private func missionSubtitle(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func stateIcon(for state: SFTPTransferState) -> some View {
        let icon: String
        let color: Color
        switch state {
        case .preparing:
            icon = "ellipsis.circle"
            color = .orange
        case .downloading:
            icon = "arrow.down.circle.fill"
            color = DesignTokens.accent
        case .uploading:
            icon = "arrow.up.circle.fill"
            color = DesignTokens.accent
        case .finished:
            icon = "checkmark.circle.fill"
            color = .green
        case .failed:
            icon = "exclamationmark.circle.fill"
            color = .red
        case .cancelled:
            icon = "xmark.circle"
            color = .secondary
        }
        return Image(systemName: icon).foregroundStyle(color)
    }

    private func byteSummary(for transfer: SFTPTransfer) -> String {
        let transferred = ByteCountFormatter.string(
            fromByteCount: Int64(min(transfer.transferredBytes, UInt64(Int64.max))),
            countStyle: .file
        )
        guard let totalBytes = transfer.totalBytes else {
            return transferred
        }
        let total = ByteCountFormatter.string(
            fromByteCount: Int64(min(totalBytes, UInt64(Int64.max))),
            countStyle: .file
        )
        let percent = Int((transfer.progress ?? 0) * 100)
        return "\(transferred) / \(total) - \(percent)%"
    }
}
