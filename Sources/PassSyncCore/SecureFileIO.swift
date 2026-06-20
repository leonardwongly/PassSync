import Darwin
import Foundation

public enum SecureFileIO {
    public static let privateDirectoryMode: mode_t = 0o700
    public static let privateFileMode: mode_t = 0o600

    public static func createPrivateDirectory(at url: URL) throws {
        let directoryURL = url.standardizedFileURL
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw PassSyncError.invalidArguments("\(directoryURL.path) exists and is not a directory.")
            }
            try setPrivatePermissionsIfOwned(path: directoryURL.path, mode: privateDirectoryMode)
            return
        }

        let missing = missingDirectoryChain(endingAt: directoryURL)
        for directory in missing.reversed() {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: Int(privateDirectoryMode)]
            )
            try setPermissions(mode: privateDirectoryMode, path: directory.path)
        }
    }

    public static func createPrivateParentDirectory(for url: URL) throws {
        try createPrivateDirectory(at: url.deletingLastPathComponent())
    }

    public static func secureExistingFile(at url: URL) throws {
        try setPermissions(mode: privateFileMode, path: url.path)
    }

    public static func writePrivateData(_ data: Data, to url: URL, overwrite: Bool = true) throws {
        try createPrivateParentDirectory(for: url)
        let destinationURL = url.standardizedFileURL
        if !overwrite, FileManager.default.fileExists(atPath: destinationURL.path) {
            throw PassSyncError.invalidArguments("Refusing to overwrite existing file at \(destinationURL.path).")
        }

        let temporaryURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(
            atPath: temporaryURL.path,
            contents: data,
            attributes: [.posixPermissions: Int(privateFileMode)]
        ) else {
            throw PassSyncError.invalidArguments("Could not create temporary file at \(temporaryURL.path).")
        }
        try setPermissions(mode: privateFileMode, path: temporaryURL.path)
        do {
            if overwrite, FileManager.default.fileExists(atPath: destinationURL.path) {
                _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
            }
            try setPermissions(mode: privateFileMode, path: destinationURL.path)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    public static func permissions(at path: String) throws -> mode_t {
        var statInfo = stat()
        guard stat(path, &statInfo) == 0 else {
            throw PassSyncError.invalidArguments("Could not inspect permissions for \(path).")
        }
        return statInfo.st_mode & mode_t(0o777)
    }

    private static func missingDirectoryChain(endingAt directoryURL: URL) -> [URL] {
        var missing: [URL] = []
        var current = directoryURL
        let fileManager = FileManager.default

        while !fileManager.fileExists(atPath: current.path) {
            missing.append(current)
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { break }
            current = parent
        }

        return missing
    }

    private static func setPermissions(mode: mode_t, path: String) throws {
        guard chmod(path, mode) == 0 else {
            throw PassSyncError.invalidArguments("Could not set private permissions on \(path).")
        }
    }

    private static func setPrivatePermissionsIfOwned(path: String, mode: mode_t) throws {
        var statInfo = stat()
        guard stat(path, &statInfo) == 0 else {
            throw PassSyncError.invalidArguments("Could not inspect permissions for \(path).")
        }
        guard statInfo.st_uid == geteuid() else { return }
        try setPermissions(mode: mode, path: path)
    }
}
