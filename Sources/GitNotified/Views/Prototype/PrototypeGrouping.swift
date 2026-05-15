// PROTOTYPE — throwaway code. Delete this file (and the Prototype/ directory) once
// the dropdown layout question is answered and the winning variant is folded into
// DropdownView proper.
//
// Question: how should the dropdown organize rows when grouped by
//           repo → PR → review-requests / CI / comments / reviews?

import Foundation

struct PRBucket: Identifiable, Hashable {
    let pr: PullRequestRef
    var reviewRequests: [DropdownRow] = []
    var ciRows: [DropdownRow] = []
    var commentRows: [DropdownRow] = []
    var reviewRows: [DropdownRow] = []

    var id: String { pr.displayRef }
    var totalCount: Int { reviewRequests.count + ciRows.count + commentRows.count + reviewRows.count }
    /// Most-recent activity across this PR's buckets — used to sort PRs newest-first.
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
enum PrototypeGrouping {
    /// Folds the four flat snapshot arrays into a repo → PR → events tree.
    /// PRs are sorted by newest activity within each repo; repos are sorted by slug.
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
