import Foundation

/// Outcome of a single poll tick — the current triage queue, the newly-active states (for OS
/// notifications), the cursor map to persist, and the standard error/timing fields the
/// AppModel uses to drive its state machine.
struct PollOutcome {
    /// Every PR currently in the triage queue, in display order (Yours first, then Reviews
    /// requested; within each section, easy wins first).
    var triagePRs: [TriagePR] = []
    /// (PR, state) pairs that just transitioned from absent → active since the previous poll.
    /// These are what fire OS notifications. Empty on first observation of a PR.
    var newlyActiveStates: [(pr: PullRequestRef, state: TriageState, role: TriageRole)] = []
    /// The full set of `triageCursors` to commit to AppState this tick. Replaces the prior
    /// map wholesale — PRs absent from the search results are dropped so a future
    /// reappearance counts as first-observed.
    var triageCursorsToCommit: [String: TriagePRCursor] = [:]
    /// Legacy per-repo failure surface. Empty under the new global-scope model; retained so
    /// AppModel's error-state machinery compiles unchanged.
    var repoFailures: [String: RepoFailure] = [:]
    /// Legacy per-repo success flag. Empty under the new global-scope model.
    var successfulRepos: Set<String> = []
    var error: GHError? = nil
    var lastCheckedAt: Date = Date()
}

final class Poller {
    /// Activity window for "stale" considerations. Retained for legacy callers; the triage
    /// queue model itself does not window — it shows the current state regardless of age.
    static let activityWindow: TimeInterval = 24 * 60 * 60

    private let gh: GHClient
    private let baseInterval: TimeInterval
    private let jitterFraction: Double
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.git-notified.poller")

    var onTick: ((PollOutcome) -> Void)?
    var stateProvider: (() -> AppState)?
    /// Retained for binary compatibility with AppModel's silence-expansion call site; no
    /// effect under the triage queue model.
    var activityWindowProvider: (() -> TimeInterval)?

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

    /// Force an immediate poll outside the scheduled cadence.
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

        // Resolve the current user's login first — needed to recognize "my" comments and
        // commits when deriving the unansweredComment state. A failure here is fatal for the
        // tick (we can't classify anything without it).
        let myLogin: String
        do {
            myLogin = try gh.currentUserLogin()
        } catch let err as GHError {
            outcome.error = err
            return outcome
        } catch {
            outcome.error = .other(exitCode: -1, stderr: error.localizedDescription)
            return outcome
        }

        // 1. Pull the two global searches.
        let yours: [GHSearchPR]
        let reviewRequested: [GHSearchPR]
        do {
            yours = try gh.searchAuthoredPRs()
        } catch let err as GHError {
            outcome.error = err
            return outcome
        } catch {
            outcome.error = .other(exitCode: -1, stderr: error.localizedDescription)
            return outcome
        }
        do {
            reviewRequested = try gh.searchReviewRequestedPRs()
        } catch let err as GHError {
            outcome.error = err
            return outcome
        } catch {
            outcome.error = .other(exitCode: -1, stderr: error.localizedDescription)
            return outcome
        }

        outcome.successfulRepos.insert("global")

        // 2. For each authored PR, fetch detail + comments and derive triage states.
        var triagePRs: [TriagePR] = []
        for pr in yours {
            let ref = PullRequestRef(
                owner: pr.owner, name: pr.repository.name, number: pr.number,
                title: pr.title, url: pr.url
            )
            let detail: GHPRDetail
            do {
                detail = try gh.prDetail(owner: pr.owner, name: pr.repository.name, number: pr.number)
            } catch {
                // Skip this PR but continue; one bad PR shouldn't blank the whole tick.
                continue
            }
            let comments = (try? gh.listAllPRIssueComments(owner: pr.owner, name: pr.repository.name, number: pr.number)) ?? []
            let states = computeStates(
                detail: detail,
                comments: comments,
                prUpdatedAt: pr.updatedAt,
                isDraft: pr.isDraft,
                myLogin: myLogin
            )
            guard !states.isEmpty else { continue }
            triagePRs.append(TriagePR(
                pr: ref, role: .author, isDraft: pr.isDraft,
                states: states, prUpdatedAt: pr.updatedAt,
                additions: detail.additions, deletions: detail.deletions
            ))
        }

        // 3. Reviews requested — single state per PR, skip drafts. Diff sizes come from
        // one batched GraphQL request (`prDiffSizes`) so this stays O(1) request instead
        // of O(N) per reviewer PR. Failure is tolerated — rows just render without sizes.
        let liveReviewers = reviewRequested.filter { !$0.isDraft }
        let sizeRefs = liveReviewers.map { (owner: $0.owner, name: $0.repository.name, number: $0.number) }
        let sizes = (try? gh.prDiffSizes(refs: sizeRefs)) ?? [:]
        for pr in liveReviewers {
            let ref = PullRequestRef(
                owner: pr.owner, name: pr.repository.name, number: pr.number,
                title: pr.title, url: pr.url
            )
            let size = sizes["\(pr.owner)/\(pr.repository.name)#\(pr.number)"]
            triagePRs.append(TriagePR(
                pr: ref, role: .reviewer, isDraft: false,
                states: [.reviewRequested], prUpdatedAt: pr.updatedAt,
                additions: size?.additions, deletions: size?.deletions
            ))
        }

        // 4. Diff against previous triage cursors → newly-active states for OS notifications.
        for triage in triagePRs {
            let key = AppState.triageKey(owner: triage.pr.owner, name: triage.pr.name, number: triage.pr.number)
            let previous = state.triageCursors[key]
            let firstObservation = previous == nil

            if !firstObservation {
                let added = triage.states.subtracting(previous?.states ?? [])
                for s in added {
                    outcome.newlyActiveStates.append((pr: triage.pr, state: s, role: triage.role))
                }
            }

            outcome.triageCursorsToCommit[key] = TriagePRCursor(
                states: triage.states,
                lastSeenAt: Date()
            )
        }

        // 5. Sort: Yours (easy wins first) then Reviews requested (newest first).
        outcome.triagePRs = sortForDisplay(triagePRs)
        return outcome
    }

    /// Public to allow unit testing the derivation rules independent of the polling loop.
    func computeStates(
        detail: GHPRDetail,
        comments: [GHIssueComment],
        prUpdatedAt: Date,
        isDraft: Bool,
        myLogin: String
    ) -> Set<TriageState> {
        var states: Set<TriageState> = []

        // CI is failing iff GitHub's aggregate rollup state on the last commit is FAILURE
        // or ERROR. That aggregate matches what github.com renders for the PR's merge dot,
        // so advisory non-required checks like `check_pr_title` don't surface here.
        let aggregate = detail.ciAggregateState?.uppercased() ?? ""
        if aggregate == "FAILURE" || aggregate == "ERROR" {
            states.insert(.ciFailing)
        }

        // Drafts surface only the CI-failing state — never approval / changes-requested /
        // unansweredComment, since they're explicitly not asking for review yet.
        guard !isDraft else { return states }

        switch detail.reviewDecision?.uppercased() {
        case "APPROVED":
            if !states.contains(.ciFailing) {
                states.insert(.approved)
            }
        case "CHANGES_REQUESTED":
            states.insert(.changesRequested)
        default:
            break
        }

        // Unanswered comment: latest top-level issue comment is from a non-me human, AND I
        // haven't commented or pushed since.
        if let lastForeign = comments
            .filter({ isHuman($0.user?.login) && $0.user?.login != myLogin })
            .max(by: { $0.created_at < $1.created_at })
        {
            let myLatestComment = comments
                .filter { $0.user?.login == myLogin }
                .map(\.created_at)
                .max() ?? .distantPast
            let myLatestCommit = detail.commits
                .filter { $0.authorLogins.contains(myLogin) }
                .compactMap(\.committedDate)
                .max() ?? .distantPast
            let myLatestActivity = max(myLatestComment, myLatestCommit)
            if myLatestActivity < lastForeign.created_at {
                states.insert(.unansweredComment)
            }
        }

        // No actionable triage state means the PR is open but nothing is blocked on you —
        // surface it as a neutral waiting row so the queue is always the full picture of
        // your open PRs.
        if states.isEmpty {
            states.insert(.waitingForReview)
        }

        return states
    }

    /// Determines whether a comment author counts as a human (not a bot). Matches GitHub's
    /// `[bot]` suffix convention used by app installations.
    private func isHuman(_ login: String?) -> Bool {
        guard let login = login else { return false }
        return !login.hasSuffix("[bot]")
    }

    /// Sorts the triage list for the dropdown: Yours block first (ordered by primary-state
    /// sortOrder, tie-break newest first), then Reviews requested (newest first).
    private func sortForDisplay(_ prs: [TriagePR]) -> [TriagePR] {
        let yours = prs.filter { $0.role == .author }.sorted { a, b in
            let ao = a.primaryState?.sortOrder ?? Int.max
            let bo = b.primaryState?.sortOrder ?? Int.max
            if ao != bo { return ao < bo }
            return a.prUpdatedAt > b.prUpdatedAt
        }
        let reviews = prs.filter { $0.role == .reviewer }.sorted { $0.prUpdatedAt > $1.prUpdatedAt }
        return yours + reviews
    }

    static func ageString(from date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86_400)d ago"
    }
}
