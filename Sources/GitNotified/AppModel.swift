import Foundation
import SwiftUI
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state: AppState
    @Published private(set) var setup: SetupStatus
    @Published private(set) var reviewRows: [DropdownRow] = []
    @Published private(set) var ciFailingRows: [DropdownRow] = []
    @Published private(set) var activityRows: [DropdownRow] = []
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var lastError: GHError?
    @Published private(set) var appCause: AppCause?
    @Published private(set) var repoFailures: [String: RepoFailure] = [:]

    /// Hysteresis: the icon flips to .error on a single failed poll but only flips back
    /// after two consecutive successful polls. Counts successes since the last failure.
    private var consecutiveSuccesses: Int = 0
    private var inErrorState: Bool = false
    @Published var showingAddRepo: Bool = false

    /// Silence notifications globally. Polling continues; cursors advance; notifications are
    /// suppressed for the duration. Silence does not persist across launches.
    @Published private(set) var silenced: Bool = false
    /// Wall-clock instant silence began; used to compute the post-resume window expansion.
    @Published private(set) var silencedSince: Date?
    /// Banner shown for the first interaction after resume — summarizes the silenced interval.
    @Published var resumeBanner: ResumeBanner?

    /// Per-tick count of suppressed notifications so the resume banner can total them.
    private var suppressedSinceSilence: Int = 0

    nonisolated private let store: Store
    nonisolated private let gh: GHClient
    private let poller: Poller
    nonisolated private let setupChecker: SetupChecker
    nonisolated private let notifications = NotificationService.shared

    init(store: Store, gh: GHClient) {
        self.store = store
        self.gh = gh
        self.state = store.load()
        self.poller = Poller(gh: gh)
        self.setupChecker = SetupChecker(gh: gh)
        self.setup = SetupStatus(ghInstalled: false, signedIn: false, hasRepo: false, pendingStep: .installGh)

        poller.stateProvider = { [weak self] in
            // Snapshot read; AppState is a value type so the closure copies safely.
            self?.state ?? AppState()
        }
        poller.activityWindowProvider = { [weak self] in
            self?.effectiveActivityWindow ?? Poller.activityWindow
        }
        poller.onTick = { [weak self] outcome in
            self?.handleTick(outcome)
        }
    }

    func bootstrap() {
        notifications.requestAuthorization()
        notifications.refreshAuthState { [weak self] state in
            if state == .denied {
                self?.appCause = .notificationsDisabled
                self?.inErrorState = true
            }
        }
        recheckSetup { [weak self] status in
            guard let self else { return }
            if status.isComplete {
                self.poller.start()
                self.poller.pokeNow()
            }
        }
    }

    // MARK: - Setup

    func recheckSetup(completion: ((SetupStatus) -> Void)? = nil) {
        let snapshot = state
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let status = self.setupChecker.evaluate(state: snapshot)
            DispatchQueue.main.async {
                self.setup = status
                completion?(status)
            }
        }
    }

    // MARK: - Repos

    func addRepo(owner: String, name: String, mode: RepoMode = .participating) {
        let watched = WatchedRepo(owner: owner, name: name, mode: mode)
        if state.repos.contains(where: { $0.id == watched.id }) { return }
        state.repos.append(watched)
        persist()
        recheckSetup { [weak self] status in
            guard let self else { return }
            if status.isComplete {
                self.poller.start()
                self.poller.pokeNow()
            }
        }
    }

    /// Changes a watched repo's mode. Picker feedback is immediate (the @Published state
    /// flips this tick); dropdown section content updates on the next poll tick.
    /// When the mode widens, no special bookkeeping is required — newly-in-scope PRs
    /// have no cursors and the Poller's per-PR first-observation rule suppresses
    /// notification firing for them, matching the no-backfill commitment.
    func setMode(slug: String, mode: RepoMode) {
        guard let idx = state.repos.firstIndex(where: { $0.id == slug }) else { return }
        guard state.repos[idx].mode != mode else { return }
        let previousMode = state.repos[idx].mode
        state.repos[idx].mode = mode

        if mode == .off || previousMode == .all {
            // Narrowing scope: drop cursors for PRs the repo no longer scans so a later
            // re-widen treats them as fresh adds (matches F8).
            clearRepoCursors(slug: slug)
            // Drop snapshot rows for this repo until next tick.
            reviewRows.removeAll { $0.pr.slug == slug }
            ciFailingRows.removeAll { $0.pr.slug == slug }
            activityRows.removeAll { $0.pr.slug == slug }
        }

        persist()
        poller.pokeNow()
    }

    func removeRepo(slug: String) {
        state.repos.removeAll { $0.id == slug }
        clearRepoCursors(slug: slug)
        reviewRows.removeAll { $0.pr.slug == slug }
        ciFailingRows.removeAll { $0.pr.slug == slug }
        activityRows.removeAll { $0.pr.slug == slug }
        persist()
        recheckSetup()
    }

    private func clearRepoCursors(slug: String) {
        let prefix = "\(slug)#"
        for key in state.cursors.keys where key.hasPrefix(prefix) {
            state.cursors.removeValue(forKey: key)
        }
    }

    func searchRepos(_ query: String, completion: @escaping ([GHRepoListing]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let repos = (try? self.gh.listRepos(limit: 100)) ?? []
            let lower = query.lowercased()
            let filtered = query.isEmpty
                ? repos
                : repos.filter { $0.nameWithOwner.lowercased().contains(lower) }
            DispatchQueue.main.async { completion(filtered) }
        }
    }

    func parseRepoString(_ raw: String) -> (owner: String, name: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        // owner/name shorthand
        if let slashIdx = trimmed.firstIndex(of: "/"), !trimmed.contains("://") {
            let owner = String(trimmed[..<slashIdx])
            let rest = String(trimmed[trimmed.index(after: slashIdx)...])
            let name = rest.split(separator: "/").first.map(String.init) ?? rest
            if !owner.isEmpty && !name.isEmpty { return (owner, name) }
        }
        // Full GitHub URL
        if let url = URL(string: trimmed), url.host?.contains("github.com") == true {
            let parts = url.path.split(separator: "/")
            if parts.count >= 2 {
                return (String(parts[0]), String(parts[1]))
            }
        }
        return nil
    }

    // MARK: - Tick handling

    private func handleTick(_ outcome: PollOutcome) {
        for (k, v) in outcome.cursorsToSet { state.cursors[k] = v }
        for k in outcome.cursorsToClear { state.cursors.removeValue(forKey: k) }
        let stateMutated = !outcome.cursorsToSet.isEmpty || !outcome.cursorsToClear.isEmpty
        if stateMutated { persist() }

        reviewRows = outcome.reviewsRequestedSnapshot
        ciFailingRows = outcome.ciFailingSnapshot
        activityRows = outcome.activitySnapshot
        lastCheckedAt = outcome.lastCheckedAt
        lastError = outcome.error
        repoFailures = outcome.repoFailures

        updateErrorStateAndCause(outcome: outcome)

        // Count what we would fire so the resume banner can summarize silenced activity.
        let totalNew = outcome.newReviewRequests.count + outcome.ciChanges.count + outcome.activityEvents.count
        if silenced {
            suppressedSinceSilence += totalNew
        }

        for ev in outcome.newReviewRequests {
            let title: String
            if let r = ev.requester {
                title = "Review requested by @\(r)"
            } else {
                title = "Review requested"
            }
            let subtitle = "\(ev.pr.displayRef) — \(ev.pr.title)"
            postIfAllowed(title: title, subtitle: subtitle, url: ev.pr.url, dedupeKey: ev.eventID)
        }

        for ev in outcome.activityEvents {
            let title: String
            switch ev.kind {
            case .comment:
                title = ev.author.map { "New comment by @\($0)" } ?? "New comment"
            case .review:
                title = ev.author.map { "Review submitted by @\($0)" } ?? "Review submitted"
            }
            let subtitle = "\(ev.pr.displayRef) — \(ev.pr.title)"
            postIfAllowed(title: title, subtitle: subtitle, url: ev.url, dedupeKey: ev.eventID)
        }

        for ev in outcome.ciChanges {
            let title: String
            switch ev.newConclusion {
            case .failing:
                title = ev.failingCheckName.map { "CI failed on \($0)" } ?? "CI failing"
            case .passing:
                title = "CI passing"
            default:
                continue
            }
            let subtitle = "\(ev.pr.displayRef) — \(ev.pr.title)"
            postIfAllowed(title: title, subtitle: subtitle, url: ev.pr.url, dedupeKey: ev.eventID)
        }
    }

    /// Routes a notification through silence: when silenced, suppresses delivery but the
    /// dropdown still updates (snapshots already reflect new activity from the outcome).
    private func postIfAllowed(title: String, subtitle: String, url: String, dedupeKey: String) {
        guard !silenced else { return }
        notifications.post(title: title, subtitle: subtitle, url: url, dedupeKey: dedupeKey)
    }

    // MARK: - Silence

    func toggleSilence() {
        if silenced {
            resumeSilence()
        } else {
            startSilence()
        }
    }

    private func startSilence() {
        silenced = true
        silencedSince = Date()
        suppressedSinceSilence = 0
    }

    private func resumeSilence() {
        let startedAt = silencedSince ?? Date()
        let minutes = max(0, Int(Date().timeIntervalSince(startedAt) / 60))
        let count = suppressedSinceSilence
        silenced = false
        silencedSince = nil
        suppressedSinceSilence = 0
        if count > 0 || minutes >= 1 {
            resumeBanner = ResumeBanner(durationMinutes: minutes, suppressedCount: count)
        }
    }

    /// 24h baseline; expanded to cover silence interval (capped at 7 days) so the user
    /// can see what they missed when resuming a long silence. The Poller reads this each
    /// tick when computing the activity window.
    var effectiveActivityWindow: TimeInterval {
        let base = Poller.activityWindow
        guard silenced, let since = silencedSince else { return base }
        let silenceSpan = Date().timeIntervalSince(since)
        return min(7 * 24 * 60 * 60, max(base, silenceSpan))
    }

    private func persist() {
        let snapshot = state
        DispatchQueue.global(qos: .utility).async { [weak self] in
            try? self?.store.save(snapshot)
        }
    }

    // MARK: - Derived

    var iconState: MenubarIconState {
        if setup.pendingStep != nil { return .setup }
        if inErrorState { return .error }
        let count = reviewRows.count + ciFailingRows.count + activityRows.count
        return count == 0 ? .idle : .active(count: count)
    }

    /// Applies hysteresis to the error icon and derives a structured cause for the banner.
    /// A poll counts as "failed" when it produced a global GHError OR when EVERY active
    /// repo failed per-repo. Per-repo failures alone do not escalate the icon.
    private func updateErrorStateAndCause(outcome: PollOutcome) {
        let activeRepoSlugs = state.repos.filter { $0.mode != .off }.map(\.id)
        let allReposFailed = !activeRepoSlugs.isEmpty
            && activeRepoSlugs.allSatisfy { outcome.repoFailures[$0] != nil }
        let tickFailed = outcome.error != nil || allReposFailed

        if tickFailed {
            consecutiveSuccesses = 0
            inErrorState = true
            appCause = mapCause(error: outcome.error, allReposFailed: allReposFailed)
        } else {
            consecutiveSuccesses += 1
            // Spec: clear only after two consecutive successful polls (F26 anti-flap).
            if consecutiveSuccesses >= 2 {
                inErrorState = false
                appCause = nil
            }
        }
    }

    private func mapCause(error: GHError?, allReposFailed: Bool) -> AppCause? {
        if let err = error {
            switch err {
            case .notSignedIn: return .notSignedIn
            case .rateLimited(let at): return .rateLimited(resetAt: at)
            case .networkUnavailable: return .networkUnavailable
            case .insufficientScope: return .insufficientScope
            case .parseError: return .parseError
            case .notInstalled: return .notSignedIn // surfaces in setup checklist already
            case .notFound, .other:
                return allReposFailed ? .networkUnavailable : nil
            }
        }
        return nil
    }

    func retryNow() {
        poller.pokeNow()
    }

    func acknowledgeCorruptedState(path: String) {
        appCause = .corruptedState(path: path)
        inErrorState = true
    }

    func resetCorruptedState() {
        state = AppState(repos: state.repos)
        appCause = nil
        inErrorState = false
        persist()
        poller.pokeNow()
    }
}
