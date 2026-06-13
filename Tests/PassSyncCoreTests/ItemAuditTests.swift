import Foundation
import Testing
@testable import PassSyncCore

@Test func itemCategoryAuditorSeparatesLoginScopeFromUnsupportedCategories() {
    let report = ItemCategoryAuditor().auditOnePasswordSummaries([
        OnePasswordItemListSummary(id: "login-1", category: "LOGIN"),
        OnePasswordItemListSummary(id: "login-2", category: "Login"),
        OnePasswordItemListSummary(id: "note-1", category: "SECURE_NOTE"),
        OnePasswordItemListSummary(id: "card-1", category: "CREDIT_CARD"),
        OnePasswordItemListSummary(id: "unknown-1", category: nil)
    ])

    #expect(report.totalCount == 5)
    #expect(report.supportedLoginCount == 2)
    #expect(report.unsupportedCount == 3)
    #expect(report.categories.first?.status == .outOfScope)
    #expect(report.categories.contains { $0.category == "LOGIN" && $0.status == .inScope && $0.count == 2 })
    #expect(report.categories.contains { $0.category == "SECURE_NOTE" && $0.status == .outOfScope })
    #expect(report.categories.contains { $0.category == "CREDIT_CARD" && $0.status == .outOfScope })
    #expect(report.categories.contains { $0.category == "UNKNOWN" && $0.status == .outOfScope })
}

@Test func itemCategoryAuditorDoesNotExposeItemTitlesInReport() throws {
    let report = ItemCategoryAuditor().auditOnePasswordSummaries([
        OnePasswordItemListSummary(id: "note-1", title: "Sensitive note title", category: "SECURE_NOTE")
    ])
    let encoded = String(data: try JSONEncoder().encode(report), encoding: .utf8) ?? ""

    #expect(!encoded.contains("Sensitive note title"))
    #expect(!encoded.contains("note-1"))
}
