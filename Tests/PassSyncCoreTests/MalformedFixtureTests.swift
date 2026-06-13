import Foundation
import Testing
@testable import PassSyncCore

@Test func malformedSimulationFixtureFailsToDecode() throws {
    let data = try Data(contentsOf: fixture("malformed-simulation-state.json"))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    do {
        _ = try decoder.decode(SimulationState.self, from: data)
        Issue.record("Expected malformed simulation fixture to fail decoding.")
    } catch DecodingError.keyNotFound(let key, _) {
        #expect(key.stringValue == "password")
    } catch {
        Issue.record("Expected missing password decode error, got \(error).")
    }
}

@Test func malformedDecisionFixtureFailsToDecode() throws {
    let data = try Data(contentsOf: fixture("malformed-decision-file.json"))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    do {
        _ = try decoder.decode(PlanDecisionFile.self, from: data)
        Issue.record("Expected malformed decision fixture to fail decoding.")
    } catch DecodingError.dataCorrupted {
        #expect(Bool(true))
    } catch {
        Issue.record("Expected invalid decision enum decode error, got \(error).")
    }
}

@Test func malformedBackupEnvelopeFixtureFailsClosedOnUnsupportedKDF() throws {
    let path = fixture("malformed-backup-envelope.json").path

    do {
        _ = try BackupManager().readEncryptedBackup(inputPath: path, passphrase: "irrelevant")
        Issue.record("Expected malformed backup envelope fixture to fail.")
    } catch let error as PassSyncError {
        #expect(error.description.contains("Unsupported backup KDF"))
    } catch {
        Issue.record("Expected PassSyncError for unsupported KDF, got \(error).")
    }
}

private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Examples")
        .appendingPathComponent(name)
}
