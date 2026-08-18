import Combine
import Foundation

@MainActor
final class SFTPTransferViewModel: ObservableObject {
    @Published private(set) var transfers: [SFTPTransfer] = []
    @Published private(set) var speeds: [UUID: Double] = [:]

    private let serverViewModel: ServerListViewModel
    private let fileManager: FileManager
    private let destinationDirectory: URL
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var reservedDestinationURLs: Set<URL> = []
    private var speedSamples: [UUID: (bytes: UInt64, date: Date)] = [:]
    private var speedUpdater: Task<Void, Never>?

    private typealias ProgressHandler = @Sendable (SFTPTransferProgress) -> Void
    private typealias TransferOperation = @Sendable (@escaping ProgressHandler) async throws -> Void

    init(
        serverViewModel: ServerListViewModel,
        fileManager: FileManager = .default,
        destinationDirectory: URL? = nil
    ) {
        self.serverViewModel = serverViewModel
        self.fileManager = fileManager
        self.destinationDirectory = destinationDirectory
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    deinit {
        speedUpdater?.cancel()
        for task in tasks.values {
            task.cancel()
        }
    }

    func startDownload(server: ServerConfiguration, remoteFile: RemoteFile) {
        guard !remoteFile.isDirectory else { return }

        let localURL = nextDestinationURL(for: remoteFile.name)
        reservedDestinationURLs.insert(localURL)
        let serverViewModel = serverViewModel
        startTransfer(
            SFTPTransfer(
                id: UUID(),
                serverID: server.id,
                serverName: server.name,
                remotePath: remoteFile.path,
                localURL: localURL,
                direction: .download,
                createdAt: Date(),
                totalBytes: remoteFile.size,
                transferredBytes: 0,
                state: .preparing,
                errorMessage: nil,
                finishedAt: nil
            )
        ) { progress in
            try await serverViewModel.downloadFile(
                for: server,
                remotePath: remoteFile.path,
                localURL: localURL,
                progress: progress
            )
        } onFinish: { [weak self] in
            self?.reservedDestinationURLs.remove(localURL)
        }
    }

    func startUpload(
        server: ServerConfiguration,
        localURL: URL,
        remoteDirectory: String
    ) {
        let fileName = localURL.lastPathComponent
        guard !fileName.isEmpty else { return }

        let remotePath = remoteDirectory == "/"
            ? "/\(fileName)"
            : "\(remoteDirectory)/\(fileName)"
        let totalBytes: UInt64?
        do {
            let fileSize = try localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            totalBytes = fileSize.flatMap { $0 >= 0 ? UInt64($0) : nil }
        } catch {
            totalBytes = nil
        }
        let serverViewModel = serverViewModel
        let accessed = localURL.startAccessingSecurityScopedResource()
        startTransfer(
            SFTPTransfer(
                id: UUID(),
                serverID: server.id,
                serverName: server.name,
                remotePath: remotePath,
                localURL: localURL,
                direction: .upload,
                createdAt: Date(),
                totalBytes: totalBytes,
                transferredBytes: 0,
                state: .preparing,
                errorMessage: nil,
                finishedAt: nil
            )
        ) { progress in
            try await serverViewModel.uploadFile(
                for: server,
                localURL: localURL,
                remotePath: remotePath,
                progress: progress
            )
        } onFinish: {
            if accessed {
                localURL.stopAccessingSecurityScopedResource()
            }
        }
    }

    private func startTransfer(
        _ transfer: SFTPTransfer,
        operation: @escaping TransferOperation,
        onFinish: (() -> Void)? = nil
    ) {
        let transferID = transfer.id
        transfers.insert(transfer, at: 0)
        speeds[transferID] = 0
        speedSamples[transferID] = (transfer.transferredBytes, Date())
        startSpeedTracking()
        tasks[transferID] = Task { [weak self] in
            defer {
                onFinish?()
                self?.tasks.removeValue(forKey: transferID)
            }

            do {
                try await operation { progress in
                    Task { @MainActor [weak self] in
                        self?.apply(progress, to: transferID)
                    }
                }
                try Task.checkCancellation()
                self?.finish(transferID, state: .finished)
            } catch is CancellationError {
                self?.finish(transferID, state: .cancelled)
            } catch {
                if Task.isCancelled {
                    self?.finish(transferID, state: .cancelled)
                } else {
                    self?.finish(
                        transferID,
                        state: .failed,
                        errorMessage: error.localizedDescription
                    )
                }
            }
        }
    }

    func cancel(_ transfer: SFTPTransfer) {
        guard let current = transfers.first(where: { $0.id == transfer.id }),
              current.state == .preparing || current.state == .downloading || current.state == .uploading else {
            return
        }
        tasks[current.id]?.cancel()
    }

    func remove(_ transfer: SFTPTransfer) {
        tasks[transfer.id]?.cancel()
        tasks.removeValue(forKey: transfer.id)
        transfers.removeAll { $0.id == transfer.id }
        speeds[transfer.id] = nil
        speedSamples[transfer.id] = nil
        stopSpeedTrackingIfIdle()
    }

    private func apply(_ progress: SFTPTransferProgress, to transferID: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == transferID }) else {
            return
        }
        guard transfers[index].state == .preparing
            || transfers[index].state == .downloading
            || transfers[index].state == .uploading else {
            return
        }
        transfers[index].transferredBytes = progress.transferredBytes
        if let totalBytes = progress.totalBytes {
            transfers[index].totalBytes = totalBytes
        }
        if transfers[index].state == .preparing {
            transfers[index].state = transfers[index].direction == .download
                ? .downloading
                : .uploading
        }
    }

    private func finish(
        _ transferID: UUID,
        state: SFTPTransferState,
        errorMessage: String? = nil
    ) {
        guard let index = transfers.firstIndex(where: { $0.id == transferID }) else {
            return
        }
        transfers[index].state = state
        transfers[index].errorMessage = errorMessage
        transfers[index].finishedAt = state == .finished || state == .failed || state == .cancelled
            ? Date()
            : nil
        speeds[transferID] = nil
        speedSamples[transferID] = nil
        stopSpeedTrackingIfIdle()
    }

    private func startSpeedTracking() {
        guard speedUpdater == nil else { return }
        speedUpdater = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                self?.updateSpeeds()
            }
        }
    }

    private func updateSpeeds() {
        let now = Date()
        for transferID in Array(speedSamples.keys) {
            guard let sample = speedSamples[transferID] else { continue }
            guard let index = transfers.firstIndex(where: { $0.id == transferID }) else {
                speedSamples[transferID] = nil
                speeds[transferID] = nil
                continue
            }
            let transfer = transfers[index]
            guard transfer.state == .preparing
                || transfer.state == .downloading
                || transfer.state == .uploading else {
                speedSamples[transferID] = nil
                speeds[transferID] = nil
                continue
            }
            let elapsed = now.timeIntervalSince(sample.date)
            guard elapsed >= 0.9 else { continue }
            let delta = transfer.transferredBytes > sample.bytes
                ? transfer.transferredBytes - sample.bytes
                : 0
            speeds[transferID] = Double(delta) / elapsed
            speedSamples[transferID] = (transfer.transferredBytes, now)
        }
    }

    private func stopSpeedTrackingIfIdle() {
        let hasActive = transfers.contains { transfer in
            transfer.state == .preparing
                || transfer.state == .downloading
                || transfer.state == .uploading
        }
        guard !hasActive else { return }
        speedUpdater?.cancel()
        speedUpdater = nil
    }

    func speedText(for transfer: SFTPTransfer) -> String? {
        guard let speed = speeds[transfer.id], speed > 0 else { return nil }
        return "\(compactByteString(speed))/s"
    }

    private func compactByteString(_ bytes: Double) -> String {
        let units = ["B", "K", "M", "G", "T"]
        var value = bytes
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return index == 0
            ? "\(Int(value))B"
            : String(format: "%.1f%@", value, units[index])
    }

    private func nextDestinationURL(for fileName: String) -> URL {
        let baseName = fileName.isEmpty ? "download" : fileName
        var candidate = destinationDirectory.appendingPathComponent(baseName)
        guard fileManager.fileExists(atPath: candidate.path) || reservedDestinationURLs.contains(candidate) else {
            return candidate
        }

        let extensionName = candidate.pathExtension
        let stem = candidate.deletingPathExtension().lastPathComponent
        var suffix = 2
        repeat {
            let name = extensionName.isEmpty
                ? "\(stem)-\(suffix)"
                : "\(stem)-\(suffix).\(extensionName)"
            candidate = destinationDirectory.appendingPathComponent(name)
            suffix += 1
        } while fileManager.fileExists(atPath: candidate.path) || reservedDestinationURLs.contains(candidate)
        return candidate
    }
}
