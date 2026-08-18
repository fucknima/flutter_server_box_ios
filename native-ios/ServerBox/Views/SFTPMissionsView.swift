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
                        "暂无传输任务",
                        systemImage: "arrow.down.circle",
                        description: Text("SFTP 下载任务会显示在这里。")
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
            .navigationTitle("SFTP 任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
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
            missionSubtitle(transfer.direction == .download ? "准备下载" : "准备上传")
            Button("取消", role: .destructive) {
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
                Text(transfer.direction == .download ? byteSummary(for: transfer) : "上传中：\(byteSummary(for: transfer))")
                if let speed = viewModel.speedText(for: transfer) {
                    Text("· \(speed)")
                }
                Spacer()
                Text(durationText(Date().timeIntervalSince(transfer.createdAt)))
                Button("取消", role: .destructive) {
                    viewModel.cancel(transfer)
                }
                .font(.caption.weight(.semibold))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .finished:
            HStack {
                missionSubtitle(transfer.direction == .download ? "已完成" : "已上传")
                if let finishedAt = transfer.finishedAt {
                    Text("耗时 \(durationText(finishedAt.timeIntervalSince(transfer.createdAt)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if transfer.direction == .download {
                    Button("在文件中打开") {
                        onShowInFiles(transfer.localURL)
                    }
                    .font(.caption.weight(.semibold))
                    ShareLink(item: transfer.localURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("分享下载的文件")
                }
            }
        case .failed:
            VStack(alignment: .leading, spacing: 4) {
                Text(transfer.errorMessage ?? "下载失败")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("移除") {
                    viewModel.remove(transfer)
                }
                .font(.caption.weight(.semibold))
            }
        case .cancelled:
            HStack {
                missionSubtitle("已取消")
                Spacer()
                Button("移除") {
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

    private func durationText(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
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
