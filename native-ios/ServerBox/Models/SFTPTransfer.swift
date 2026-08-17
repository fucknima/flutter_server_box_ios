import Foundation

enum SFTPTransferState: String, Sendable {
    case preparing
    case downloading
    case uploading
    case finished
    case failed
    case cancelled
}

enum SFTPTransferDirection: String, Sendable {
    case download
    case upload
}

enum SFTPRemoteMutation: Sendable {
    case createDirectory(path: String)
    case createFile(path: String)
    case rename(oldPath: String, newPath: String)
    case remove(path: String, isDirectory: Bool, recursive: Bool)
    case chmod(path: String, permissions: UInt32)
    case writeFile(path: String, content: String)
}

struct SFTPTransferProgress: Equatable, Sendable {
    let transferredBytes: UInt64
    let totalBytes: UInt64?

    var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else {
            return totalBytes == 0 ? 1 : nil
        }
        return min(1, Double(transferredBytes) / Double(totalBytes))
    }
}

struct SFTPTransfer: Equatable, Identifiable, Sendable {
    let id: UUID
    let serverID: UUID
    let serverName: String
    let remotePath: String
    let localURL: URL
    let direction: SFTPTransferDirection
    let createdAt: Date
    var totalBytes: UInt64?
    var transferredBytes: UInt64
    var state: SFTPTransferState
    var errorMessage: String?
    var finishedAt: Date?

    var fileName: String {
        let name = URL(fileURLWithPath: remotePath).lastPathComponent
        return name.isEmpty ? remotePath : name
    }

    var progress: Double? {
        SFTPTransferProgress(
            transferredBytes: transferredBytes,
            totalBytes: totalBytes
        ).fractionCompleted
    }
}
