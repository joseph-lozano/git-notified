import Foundation

/// Per-PR aggregation of events used by the dropdown's repo-grouped layout.
/// PRs are ordered by newest activity within each repo; repos by slug.
struct PRBucket: Identifiable, Hashable {
    let pr: PullRequestRef
    var reviewRequests: [DropdownRow] = []
    var ciRows: [DropdownRow] = []
    var commentRows: [DropdownRow] = []
    var reviewRows: [DropdownRow] = []

    var id: String { pr.displayRef }
    var totalCount: Int { reviewRequests.count + ciRows.count + commentRows.count + reviewRows.count }
    var newestActivity: Date {
        ([reviewRequests, ciRows, commentRows, reviewRows].flatMap { $0 })
            .map(\.sortKey).max() ?? .distantPast
    }
}

struct RepoBucket: Identifiable, Hashable {
    let slug: String
    var prs: [PRBucket] = []

    var id: String { slug }
    var totalCount: Int { prs.reduce(0) { $0 + $1.totalCount } }
}

@MainActor
enum DropdownGrouping {
    /// Folds the four flat snapshot arrays into a repo → PR → events tree.
    static func group(model: AppModel) -> [RepoBucket] {
        var byRepo: [String: [String: PRBucket]] = [:]
        for r in model.reviewRows { add(r, into: &byRepo, keyPath: \.reviewRequests) }
        for r in model.ciFailingRows { add(r, into: &byRepo, keyPath: \.ciRows) }
        for r in model.commentRows { add(r, into: &byRepo, keyPath: \.commentRows) }
        for r in model.reviewSubmissionRows { add(r, into: &byRepo, keyPath: \.reviewRows) }

        return byRepo
            .map { slug, prDict in
                let prs = prDict.values.sorted { $0.newestActivity > $1.newestActivity }
                return RepoBucket(slug: slug, prs: prs)
            }
            .sorted { $0.slug < $1.slug }
    }

    private static func add(_ row: DropdownRow,
                            into byRepo: inout [String: [String: PRBucket]],
                            keyPath: WritableKeyPath<PRBucket, [DropdownRow]>) {
        let repoSlug = row.pr.slug
        let prKey = row.pr.displayRef
        var prDict = byRepo[repoSlug] ?? [:]
        var bucket = prDict[prKey] ?? PRBucket(pr: row.pr)
        bucket[keyPath: keyPath].append(row)
        prDict[prKey] = bucket
        byRepo[repoSlug] = prDict
    }
}

/// A single event row flattened for the dropdown's repo-grouped layout. Carries enough
/// context to render PR title + reason + age without rebuilding the bucket tree at render.
struct EventRow: Identifiable, Hashable {
    enum Kind: String {
        case reviewRequested, ciFailing, comment, review
        var glyph: String {
            switch self {
            case .reviewRequested: return "person.crop.circle.badge.questionmark"
            case .ciFailing: return "xmark.octagon.fill"
            case .comment: return "text.bubble"
            case .review: return "checkmark.message"
            }
        }
    }
    let id: String
    let kind: Kind
    let pr: PullRequestRef
    let reason: String
    let age: String
    let url: String
    let sortKey: Date

    static func from(_ row: DropdownRow, kind: Kind, reasonPrefix: String? = nil) -> EventRow {
        let reason: String
        if let p = reasonPrefix {
            reason = "#\(row.pr.number) · \(p) · \(row.summary)"
        } else {
            reason = "#\(row.pr.number) · \(row.summary)"
        }
        return EventRow(
            id: row.id,
            kind: kind,
            pr: row.pr,
            reason: reason,
            age: row.age,
            url: row.url,
            sortKey: row.sortKey
        )
    }
}
