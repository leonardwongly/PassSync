import Foundation

public struct ItemCategoryAuditReport: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var provider: Provider
    public var totalCount: Int
    public var supportedLoginCount: Int
    public var unsupportedCount: Int
    public var categories: [ItemCategoryAuditCount]
    public var notes: [String]

    public init(
        generatedAt: Date = Date(),
        provider: Provider,
        totalCount: Int,
        supportedLoginCount: Int,
        unsupportedCount: Int,
        categories: [ItemCategoryAuditCount],
        notes: [String]
    ) {
        self.generatedAt = generatedAt
        self.provider = provider
        self.totalCount = totalCount
        self.supportedLoginCount = supportedLoginCount
        self.unsupportedCount = unsupportedCount
        self.categories = categories
        self.notes = notes
    }
}

public struct ItemCategoryAuditCount: Codable, Equatable, Sendable, Identifiable {
    public var category: String
    public var count: Int
    public var status: ItemCategoryMigrationStatus
    public var detail: String

    public init(category: String, count: Int, status: ItemCategoryMigrationStatus, detail: String) {
        self.category = category
        self.count = count
        self.status = status
        self.detail = detail
    }

    public var id: String { category }
}

public enum ItemCategoryMigrationStatus: String, Codable, Equatable, Sendable {
    case inScope = "in-scope"
    case outOfScope = "out-of-scope"
}

public struct ItemCategoryAuditor: Sendable {
    public init() {}

    public func auditOnePasswordSummaries(_ summaries: [OnePasswordItemListSummary]) -> ItemCategoryAuditReport {
        let grouped = Dictionary(grouping: summaries) { normalizeCategory($0.category) }
        let categories = grouped
            .map { category, items in
                let status = status(for: category)
                return ItemCategoryAuditCount(
                    category: category,
                    count: items.count,
                    status: status,
                    detail: detail(for: category, status: status)
                )
            }
            .sorted { left, right in
                if left.status != right.status {
                    return left.status == .outOfScope
                }
                if left.count != right.count {
                    return left.count > right.count
                }
                return left.category < right.category
            }
        let supported = categories.filter { $0.status == .inScope }.reduce(0) { $0 + $1.count }
        let unsupported = categories.filter { $0.status == .outOfScope }.reduce(0) { $0 + $1.count }
        return ItemCategoryAuditReport(
            provider: .onePassword,
            totalCount: summaries.count,
            supportedLoginCount: supported,
            unsupportedCount: unsupported,
            categories: categories,
            notes: [
                "Category audit uses 1Password item summaries only; it does not fetch or print item details or secrets.",
                "Only website/app login records are in v1 sync scope. Non-login categories are reported but not migrated."
            ]
        )
    }

    private func normalizeCategory(_ category: String?) -> String {
        guard let category, !category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "UNKNOWN"
        }
        return category.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private func status(for category: String) -> ItemCategoryMigrationStatus {
        category == "LOGIN" ? .inScope : .outOfScope
    }

    private func detail(for category: String, status: ItemCategoryMigrationStatus) -> String {
        switch status {
        case .inScope:
            return "Website/app login category is eligible for v1 planning, subject to passkey and TOTP safety checks."
        case .outOfScope:
            return "\(category) is outside v1 scope and will not be synced."
        }
    }
}

public struct OnePasswordItemListSummary: Codable, Equatable, Sendable {
    public var id: String
    public var title: String?
    public var category: String?

    public init(id: String, title: String? = nil, category: String? = nil) {
        self.id = id
        self.title = title
        self.category = category
    }
}
