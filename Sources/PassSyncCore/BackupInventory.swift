import Foundation

public struct BackupInventoryItem: Codable, Equatable, Sendable, Identifiable {
    public var path: String
    public var fileSize: UInt64
    public var modifiedAt: Date?
    public var envelope: BackupEnvelopeInfo?
    public var error: String?

    public init(path: String, fileSize: UInt64, modifiedAt: Date?, envelope: BackupEnvelopeInfo?, error: String?) {
        self.path = path
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.envelope = envelope
        self.error = error
    }

    public var id: String { path }
}

public struct BackupInventory: Sendable {
    public init() {}

    public func scan(path: String) -> [BackupInventoryItem] {
        let url = URL(fileURLWithPath: path)
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return [
                BackupInventoryItem(
                    path: url.path,
                    fileSize: 0,
                    modifiedAt: nil,
                    envelope: nil,
                    error: "Path does not exist."
                )
            ]
        }

        let files: [URL]
        if isDirectory.boolValue {
            files = (try? fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ))?.filter { candidate in
                candidate.pathExtension == "psbackup"
            } ?? []
        } else {
            files = [url]
        }

        return files
            .sorted { $0.path < $1.path }
            .map(item)
    }

    private func item(for url: URL) -> BackupInventoryItem {
        let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = UInt64(resourceValues?.fileSize ?? 0)
        let modifiedAt = resourceValues?.contentModificationDate
        do {
            let envelope = try BackupManager().inspectEncryptedBackup(inputPath: url.path)
            return BackupInventoryItem(path: url.path, fileSize: size, modifiedAt: modifiedAt, envelope: envelope, error: nil)
        } catch {
            return BackupInventoryItem(path: url.path, fileSize: size, modifiedAt: modifiedAt, envelope: nil, error: String(describing: error))
        }
    }
}
