import Foundation
import Testing
@testable import PassSyncCore

@Test func examplesIncludeExpectedFixtures() {
    let names = Set(SimulationExamples.all.map(\.name))

    #expect(names.contains("empty"))
    #expect(names.contains("minimal"))
    #expect(names.contains("conflict"))
    #expect(names.contains("totp"))
    #expect(names.contains("passkey"))
    #expect(names.contains("password-only-totp"))
    #expect(names.contains("duplicates"))
    #expect(names.contains("restore-missing"))
    #expect(names.contains("bidirectional"))
}

@Test func examplesEncodeAsSimulationState() throws {
    let example = try #require(SimulationExamples.named("bidirectional"))
    let data = try JSONEncoder().encode(example.state)
    let decoded = try JSONDecoder().decode(SimulationState.self, from: data)

    #expect(decoded.onePasswordRecords.count == example.state.onePasswordRecords.count)
    #expect(decoded.appleRecords.count == example.state.appleRecords.count)
}
