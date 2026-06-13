import Foundation
import Testing
@testable import PassSyncCore

@Test func doctorChecksAuditDirectoryAndReleaseScript() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let backupPath = directory.appendingPathComponent("backup.psbackup").path
    let auditPath = directory.appendingPathComponent("audit").path
    let scriptPath = directory.appendingPathComponent("package_release.sh").path
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("#!/usr/bin/env bash\n".utf8).write(to: URL(fileURLWithPath: scriptPath))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

    let report = Doctor(runner: ProcessRunner(), timeoutSeconds: 2).run(options: DoctorOptions(
        opPath: "/bin/echo",
        backupPath: backupPath,
        auditPath: auditPath,
        releaseScriptPath: scriptPath
    ))

    #expect(report.checks.contains { $0.id == "backup.writable" && $0.severity == .pass })
    #expect(report.checks.contains { $0.id == "audit.writable" && $0.severity == .pass })
    #expect(report.checks.contains { $0.id == "release.script" && $0.severity == .pass })
}

@Test func doctorReportsAppBundleMetadataAndUnsignedWarning() throws {
    let app = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("PassSync.app")
    let contents = app.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let plist = contents.appendingPathComponent("Info.plist")
    let info: NSDictionary = [
        "CFBundleIdentifier": "com.example.PassSync",
        "CFBundleShortVersionString": "9.9.9"
    ]
    info.write(to: plist, atomically: true)

    let report = Doctor(runner: ProcessRunner(), timeoutSeconds: 2).run(options: DoctorOptions(
        opPath: "/bin/echo",
        appBundlePath: app.path
    ))

    #expect(report.checks.contains { $0.id == "app.bundle" && $0.severity == .pass })
    #expect(report.checks.contains { $0.id == "app.bundle.version" && $0.detail.contains("9.9.9") })
    #expect(report.checks.contains { $0.id == "app.signing" })
}
