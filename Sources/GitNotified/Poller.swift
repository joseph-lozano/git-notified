import Foundation

/// Outcome of a single poll tick — what's new (fire notifications), what's currently outstanding
/// (drive the dropdown), and what cursors to commit (apply to AppState then persist).
struct PollOutcome {
    var newReviewRequests: [ReviewRequest] = []
    var reviewsRequestedSnapshot: [DropdownRow] = []
    var ciChanges: [CIChangeEvent] = []
    var ciFailingSnapshot: [DropdownRow] = []
    var activityEvents: [ActivityEvent] = []
    var activitySnapshot: [DropdownRow] = []
    var cursorsToSet: [String: Cursor] = [:]
    var cursorsToClear: [String] = []
    var error: GHError? = nil
    var lastCheckedAt: Date = Date()
}

final class Poller {
    /// Activity window for the dropdown "New comments & reviews" section. The window
    /// is measured against the GitHub-reported event timestamp, not the local clock.
    static let activityWindow: TimeInterval = 24 * 60 * 60

    private let gh: GHClient
    private let baseInterval: TimeInterval
    private let jitterFraction: Double
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.git-notified.poller")

    var onTick: ((PollOutcome) -> Void)?
    var stateProvider: (() -> AppState)?

    init(gh: GHClient, baseInterval: TimeInterval = 60, jitterFraction: Double = 0.15) {
        self.gh = gh
        self.baseInterval = baseInterval
        self.jitterFraction = jitterFraction
    }

    func start() {
        stop()
        scheduleNext(after: 1.0)
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Force an immediate poll outside the scheduled cadence. Used after setup completion or
    /// "add repository" to avoid the first-tick latency gap.
    func pokeNow() {
        queue.async { [weak self] in self?.tick() }
    }

    private func scheduleNext(after seconds: TimeInterval) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + seconds, repeating: .never)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        guard let provider = stateProvider else { return }
        let outcome = runOnce(state: provider())
        DispatchQueue.main.async { [weak self] in
            self?.onTick?(outcome)
        }
        scheduleNext(after: nextInterval())
    }

    private func nextInterval() -> TimeInterval {
        let jitter = baseInterval * jitterFraction * Double.random(in: -1...1)
        return max(5, baseInterval + jitter)
    }

    func runOnce(state: AppState) -> PollOutcome {
        var outcome = PollOutcome()
        let activeRepos = state.repos.filter { $0.mode != .off }
        guard !activeRepos.isEmpty else { return outcome }

        var observedReviewKeys = Set<String>()
        var observedCIKeys = Set<String>()
        var observedCommentKeys = Set<String>()
        var observedReviewActivityKeys = Set<String>()
        var firstError: GHError?

        // Window threshold for activity (comments/reviews) — 24h before now.
        let windowStart = Date().addingTimeInterval(-Self.activityWindow)

        // Pre-compute the set of PR scopes we've ever observed (any event-type cursor exists).
        // A PR absent from this set is "first observed" this tick — seed cursors but suppress
        // notification firing so we don't flood on initial add or mode-widen.
        let knownPRScopes: Set<String> = {
            var scopes = Set<String>()
            for key in state.cursors.keys {
                if let colon = key.lastIndex(of: ":") {
                    scopes.insert(String(key[..<colon]))
                }
            }
            return scopes
        }()
        func isFirstObservation(repo: WatchedRepo, prNumber: Int) -> Bool {
            !knownPRScopes.contains("\(repo.slug)#\(prNumber)")
        }

        for repo in activeRepos {
            // 1. Review requests — independent of mode; always show PRs where review is requested.
            do {
                let prs = try gh.listReviewRequestedPRs(owner: repo.owner, name: repo.name)
                for pr in prs {
                    let prRef = pullRequestRef(repo: repo, pr: pr.number, title: pr.title, url: pr.url)
                    let key = AppState.cursorKey(repo: repo, prNumber: pr.number, type: .reviewRequested)
                    observedReviewKeys.insert(key)
                    let eventID = "\(repo.slug)#\(pr.number):review_requested"
                    let requester = pr.author?.login ?? nil
                    let isNewCursor = state.cursors[key] == nil && outcome.cursorsToSet[key] == nil
                    let firstObs = isFirstObservation(repo: repo, prNumber: pr.number)

                    if isNewCursor {
                        outcome.cursorsToSet[key] = Cursor(updatedAt: pr.updatedAt, eventID: eventID)
                        if !firstObs {
                            outcome.newReviewRequests.append(ReviewRequest(
                                pr: prRef,
                                requestedAt: pr.updatedAt,
                                requester: requester,
                                eventID: eventID
                            ))
                        }
                    }
                    outcome.reviewsRequestedSnapshot.append(DropdownRow(
                        id: eventID,
                        pr: prRef,
                        summary: requester.map { "requested via @\($0)" } ?? "review requested",
                        age: Self.ageString(from: pr.updatedAt),
                        url: pr.url,
                        sortKey: pr.updatedAt
                    ))
                }
            } catch let err as GHError {
                if firstError == nil { firstError = err }
                continue // Skip CI/activity for this repo if we can't even list PRs.
            } catch {
                if firstError == nil { firstError = .other(exitCode: -1, stderr: error.localizedDescription) }
                continue
            }

            // 2. CI state and comments/reviews on in-scope PRs (per repo.mode)
            do {
                let inScope = try gh.listPRsWithCI(owner: repo.owner, name: repo.name, scope: repo.mode)
                for pr in inScope {
                    let prRef = pullRequestRef(repo: repo, pr: pr.number, title: pr.title, url: pr.url)
                    let firstObs = isFirstObservation(repo: repo, prNumber: pr.number)

                    // 2a. CI state
                    let ciKey = AppState.cursorKey(repo: repo, prNumber: pr.number, type: .ciState)
                    observedCIKeys.insert(ciKey)
                    let conclusion = pr.ciConclusion
                    let previousRaw: String? = state.cursors[ciKey]?.eventID
                    let previousConclusion: CIConclusion = previousRaw.flatMap(CIConclusion.init(rawValue:)) ?? .none
                    let hadPrevious = state.cursors[ciKey] != nil

                    var ciShouldFire = false
                    if hadPrevious && !firstObs {
                        if previousConclusion == .passing && conclusion == .failing { ciShouldFire = true }
                        if previousConclusion == .failing && conclusion == .passing { ciShouldFire = true }
                    }
                    if conclusion == .failing || conclusion == .passing {
                        outcome.cursorsToSet[ciKey] = Cursor(updatedAt: pr.updatedAt, eventID: conclusion.rawValue)
                    }
                    if ciShouldFire {
                        outcome.ciChanges.append(CIChangeEvent(
                            pr: prRef,
                            newConclusion: conclusion,
                            failingCheckName: pr.failingCheckName,
                            eventID: "\(repo.slug)#\(pr.number):ci_state:\(conclusion.rawValue):\(Int(pr.updatedAt.timeIntervalSince1970))"
                        ))
                    }
                    if conclusion == .failing {
                        let summary = pr.failingCheckName.map { "failing: \($0)" } ?? "failing checks"
                        outcome.ciFailingSnapshot.append(DropdownRow(
                            id: "\(repo.slug)#\(pr.number):ci",
                            pr: prRef,
                            summary: summary,
                            age: Self.ageString(from: pr.updatedAt),
                            url: pr.url,
                            sortKey: pr.updatedAt
                        ))
                    }

                    // 2b. Comments — fetch since the last 24h. Skip on per-PR error so one
                    // bad PR does not blank the whole tick.
                    let commentKey = AppState.cursorKey(repo: repo, prNumber: pr.number, type: .comment)
                    observedCommentKeys.insert(commentKey)
                    let commentCursor = state.cursors[commentKey]
                    var newestCommentCursor: Cursor? = commentCursor

                    if let comments = try? gh.listPRIssueComments(
                        owner: repo.owner, name: repo.name, number: pr.number, since: windowStart
                    ) {
                        for c in comments where c.created_at >= windowStart {
                            let cid = String(c.id)
                            let isNew = commentCursor.map { $0.isNewer(than: c.created_at, id: cid) } ?? true
                            if isNew {
                                if !firstObs && commentCursor != nil {
                                    outcome.activityEvents.append(ActivityEvent(
                                        kind: .comment,
                                        pr: prRef,
                                        author: c.user?.login ?? nil,
                                        createdAt: c.created_at,
                                        url: c.html_url,
                                        eventID: "\(repo.slug)#\(pr.number):comment:\(cid)",
                                        bodyExcerpt: shortExcerpt(c.body)
                                    ))
                                }
                                // Advance candidate cursor monotonically.
                                if let cur = newestCommentCursor {
                                    if cur.isNewer(than: c.created_at, id: cid) {
                                        newestCommentCursor = Cursor(updatedAt: c.created_at, eventID: cid)
                                    }
                                } else {
                                    newestCommentCursor = Cursor(updatedAt: c.created_at, eventID: cid)
                                }
                            }
                            outcome.activitySnapshot.append(DropdownRow(
                                id: "\(repo.slug)#\(pr.number):comment:\(cid)",
                                pr: prRef,
                                summary: "comment by @\(c.user?.login ?? "?")",
                                age: Self.ageString(from: c.created_at),
                                url: c.html_url,
                                sortKey: c.created_at
                            ))
                        }
                    }
                    if let cur = newestCommentCursor, cur != commentCursor {
                        outcome.cursorsToSet[commentKey] = cur
                    } else if commentCursor == nil {
                        // No comments yet — seed with epoch so subsequent runs skip the firstObservation gate.
                        outcome.cursorsToSet[commentKey] = Cursor(updatedAt: windowStart, eventID: "")
                    }

                    // 2c. Reviews — REST endpoint doesn't take `since`; filter client-side.
                    let reviewKey = AppState.cursorKey(repo: repo, prNumber: pr.number, type: .review)
                    observedReviewActivityKeys.insert(reviewKey)
                    let reviewCursor = state.cursors[reviewKey]
                    var newestReviewCursor: Cursor? = reviewCursor

                    if let reviews = try? gh.listPRReviews(owner: repo.owner, name: repo.name, number: pr.number) {
                        for r in reviews {
                            guard let submitted = r.submitted_at, submitted >= windowStart else { continue }
                            let rid = String(r.id)
                            let isNew = reviewCursor.map { $0.isNewer(than: submitted, id: rid) } ?? true
                            if isNew {
                                if !firstObs && reviewCursor != nil {
                                    outcome.activityEvents.append(ActivityEvent(
                                        kind: .review,
                                        pr: prRef,
                                        author: r.user?.login ?? nil,
                                        createdAt: submitted,
                                        url: r.html_url,
                                        eventID: "\(repo.slug)#\(pr.number):review:\(rid)",
                                        bodyExcerpt: shortExcerpt(r.body)
                                    ))
                                }
                                if let cur = newestReviewCursor {
                                    if cur.isNewer(than: submitted, id: rid) {
                                        newestReviewCursor = Cursor(updatedAt: submitted, eventID: rid)
                                    }
                                } else {
                                    newestReviewCursor = Cursor(updatedAt: submitted, eventID: rid)
                                }
                            }
                            outcome.activitySnapshot.append(DropdownRow(
                                id: "\(repo.slug)#\(pr.number):review:\(rid)",
                                pr: prRef,
                                summary: "review by @\(r.user?.login ?? "?") (\((r.state ?? "submitted").lowercased()))",
                                age: Self.ageString(from: submitted),
                                url: r.html_url,
                                sortKey: submitted
                            ))
                        }
                    }
                    if let cur = newestReviewCursor, cur != reviewCursor {
                        outcome.cursorsToSet[reviewKey] = cur
                    } else if reviewCursor == nil {
                        outcome.cursorsToSet[reviewKey] = Cursor(updatedAt: windowStart, eventID: "")
                    }
                }
            } catch let err as GHError {
                if firstError == nil { firstError = err }
            } catch {
                if firstError == nil { firstError = .other(exitCode: -1, stderr: error.localizedDescription) }
            }

        }

        // Clear cursors for entities no longer observed so a re-request / re-introduction
        // fires fresh notifications.
        clearVanished(state: state, keys: observedReviewKeys, suffix: .reviewRequested, into: &outcome)
        clearVanished(state: state, keys: observedCIKeys, suffix: .ciState, into: &outcome)
        clearVanished(state: state, keys: observedCommentKeys, suffix: .comment, into: &outcome)
        clearVanished(state: state, keys: observedReviewActivityKeys, suffix: .review, into: &outcome)

        outcome.reviewsRequestedSnapshot.sort { $0.sortKey > $1.sortKey }
        outcome.ciFailingSnapshot.sort { $0.sortKey > $1.sortKey }
        outcome.activitySnapshot.sort { $0.sortKey > $1.sortKey }
        outcome.error = firstError
        return outcome
    }

    static func ageString(from date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86_400)d ago"
    }

    // MARK: - Helpers

    private func pullRequestRef(repo: WatchedRepo, pr: Int, title: String, url: String) -> PullRequestRef {
        PullRequestRef(owner: repo.owner, name: repo.name, number: pr, title: title, url: url)
    }

    private func shortExcerpt(_ body: String?) -> String? {
        guard let body = body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else { return nil }
        let cleaned = body.replacingOccurrences(of: "\n", with: " ")
        if cleaned.count <= 80 { return cleaned }
        return String(cleaned.prefix(77)) + "…"
    }

    private func clearVanished(state: AppState, keys observed: Set<String>, suffix: EventType, into outcome: inout PollOutcome) {
        let s = ":\(suffix.rawValue)"
        for key in state.cursors.keys where key.hasSuffix(s) {
            if !observed.contains(key) {
                outcome.cursorsToClear.append(key)
            }
        }
    }
}
