import Foundation

/// Outcome of a single poll tick — what's new (fire notifications), what's currently outstanding
/// (drive the dropdown), and what cursors to commit (apply to AppState then persist).
struct PollOutcome {
    var newReviewRequests: [ReviewRequest] = []
    var reviewsRequestedSnapshot: [DropdownRow] = []
    var ciChanges: [CIChangeEvent] = []
    var ciFailingSnapshot: [DropdownRow] = []
    var cursorsToSet: [String: Cursor] = [:]
    var cursorsToClear: [String] = []
    var error: GHError? = nil
    var lastCheckedAt: Date = Date()
}

final class Poller {
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
        var firstError: GHError?

        for repo in activeRepos {
            // Review requests
            do {
                let prs = try gh.listReviewRequestedPRs(owner: repo.owner, name: repo.name)
                for pr in prs {
                    let prRef = PullRequestRef(
                        owner: repo.owner,
                        name: repo.name,
                        number: pr.number,
                        title: pr.title,
                        url: pr.url
                    )
                    let key = AppState.cursorKey(repo: repo, prNumber: pr.number, type: .reviewRequested)
                    observedReviewKeys.insert(key)
                    let eventID = "\(repo.slug)#\(pr.number):review_requested"

                    let requester = pr.author?.login ?? nil
                    let isNew = state.cursors[key] == nil && outcome.cursorsToSet[key] == nil
                    if isNew {
                        outcome.newReviewRequests.append(ReviewRequest(
                            pr: prRef,
                            requestedAt: pr.updatedAt,
                            requester: requester,
                            eventID: eventID
                        ))
                        outcome.cursorsToSet[key] = Cursor(updatedAt: pr.updatedAt, eventID: eventID)
                    }
                    outcome.reviewsRequestedSnapshot.append(DropdownRow(
                        id: eventID,
                        pr: prRef,
                        summary: requester.map { "requested via @\($0)" } ?? "review requested",
                        age: Self.ageString(from: pr.updatedAt),
                        url: pr.url
                    ))
                }
            } catch let err as GHError {
                if firstError == nil { firstError = err }
            } catch {
                if firstError == nil { firstError = .other(exitCode: -1, stderr: error.localizedDescription) }
            }

            // CI state for involved PRs in this repo
            do {
                let prs = try gh.listInvolvedPRsWithCI(owner: repo.owner, name: repo.name)
                for pr in prs {
                    let prRef = PullRequestRef(
                        owner: repo.owner,
                        name: repo.name,
                        number: pr.number,
                        title: pr.title,
                        url: pr.url
                    )
                    let key = AppState.cursorKey(repo: repo, prNumber: pr.number, type: .ciState)
                    observedCIKeys.insert(key)

                    let conclusion = pr.ciConclusion
                    let previous = state.cursors[key]?.eventID
                    let previousConclusion: CIConclusion = previous.flatMap { CIConclusion(rawValue: $0) } ?? .none

                    // Notification trigger: only fire when transitioning into or out of `failing`,
                    // and never on the first observation of an already-failing PR (no backfill).
                    var shouldFire = false
                    if previous != nil {
                        if previousConclusion == .passing && conclusion == .failing { shouldFire = true }
                        if previousConclusion == .failing && conclusion == .passing { shouldFire = true }
                    }

                    // Persist the new state when settled (failing or passing); never persist in_progress
                    // — leave the cursor as the last settled value so a brief in_progress dip doesn't
                    // suppress a later passing→failing transition notification.
                    if conclusion == .failing || conclusion == .passing {
                        outcome.cursorsToSet[key] = Cursor(updatedAt: pr.updatedAt, eventID: conclusion.rawValue)
                    }

                    if shouldFire {
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
                            url: pr.url
                        ))
                    }
                }
            } catch let err as GHError {
                if firstError == nil { firstError = err }
            } catch {
                if firstError == nil { firstError = .other(exitCode: -1, stderr: error.localizedDescription) }
            }
        }

        // Clear review-request cursors whose PRs are no longer pending so a re-request fires fresh.
        let reviewSuffix = ":\(EventType.reviewRequested.rawValue)"
        for key in state.cursors.keys where key.hasSuffix(reviewSuffix) {
            if !observedReviewKeys.contains(key) {
                outcome.cursorsToClear.append(key)
            }
        }
        // Clear CI cursors for PRs we no longer see (closed, merged, or scope change).
        let ciSuffix = ":\(EventType.ciState.rawValue)"
        for key in state.cursors.keys where key.hasSuffix(ciSuffix) {
            if !observedCIKeys.contains(key) {
                outcome.cursorsToClear.append(key)
            }
        }

        outcome.reviewsRequestedSnapshot.sort { $0.pr.displayRef < $1.pr.displayRef }
        outcome.ciFailingSnapshot.sort { $0.pr.displayRef < $1.pr.displayRef }
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
}
