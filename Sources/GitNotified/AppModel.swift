import Foundation
import SwiftUI
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state: AppState
    @Published private(set) var setup: SetupStatus

    /// The single triage queue published to the dropdown. Replaces the four event-typed
    /// row arrays from the prior event-feed model.
    @Published private(set) var triageRows: [TriageRow] = []

    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var lastError: GHError?
    @Published private(set) var appCause: AppCause?
    @Published private(set) var repoFailures: [String: RepoFailure] = [:]

    /// Hysteresis: the icon flips to .error on a single failed poll but only flips back
    /// after two consecutive successful polls.
    private var consecutiveSuccesses: Int = 0
    private var inErrorState: Bool = false

    /// Silence notifications globally. Polling continues; cursors advance; notifications are
    /// suppressed for the duration. Silence does not persist across launches.
    @Published private(set) var silenced: Bool = false
    @Published private(set) var silencedSince: Date?
    @Published var resumeBanner: ResumeBanner?

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
        self.setup = SetupStatus(ghInstalled: false, ghReachable: false, signedIn: false, authNetworkError: false, pendingStep: .installGh)

        poller.stateProvider = { [weak self] in
            self?.state ?? AppState()
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
                if status.authNetworkError {
                    self.appCause = .networkUnavailable
                    self.inErrorState = true
                }
                completion?(status)
            }
        }
    }

    // MARK: - Tick handling

    private func handleTick(_ outcome: PollOutcome) {
        // Commit the new triage cursor map wholesale — PRs absent from the search results
        // are dropped so a future reappearance counts as first-observed.
        state.triageCursors = outcome.triageCursorsToCommit

        // hiddenPRs is intentionally never auto-pruned: a PR can temporarily fall out of
        // search results (transient API errors, the 200-result cap, criteria churn) and
        // any pruning here would silently un-hide it on the next reappearance. The user
        // clears hides explicitly via the "Show N hidden" footer.

        persist()

        // Build the published view-model rows from the outcome's sorted triage list,
        // filtering out user-hidden PRs.
        let hidden = state.hiddenPRs
        triageRows = outcome.triagePRs.compactMap { triage -> TriageRow? in
            guard let primary = triage.primaryState else { return nil }
            let key = AppState.triageKey(owner: triage.pr.owner, name: triage.pr.name, number: triage.pr.number)
            guard !hidden.contains(key) else { return nil }
            return TriageRow(
                id: key,
                role: triage.role,
                pr: triage.pr,
                state: primary,
                age: Poller.ageString(from: triage.prUpdatedAt),
                sortKey: triage.prUpdatedAt
            )
        }

        lastCheckedAt = outcome.lastCheckedAt
        lastError = outcome.error
        repoFailures = outcome.repoFailures

        updateErrorStateAndCause(outcome: outcome)

        // Count what would have fired so the resume banner can total silenced activity.
        let totalNew = outcome.newlyActiveStates.count
        if silenced {
            suppressedSinceSilence += totalNew
        }

        for ev in outcome.newlyActiveStates {
            guard ev.state.isActionable else { continue }
            let key = AppState.triageKey(owner: ev.pr.owner, name: ev.pr.name, number: ev.pr.number)
            guard !state.hiddenPRs.contains(key) else { continue }
            let title = ev.state.label
            let subtitle = "\(ev.pr.displayRef) — \(ev.pr.title)"
            let dedupeKey = "\(ev.pr.displayRef):\(ev.state.rawValue)"
            postIfAllowed(title: title, subtitle: subtitle, url: ev.pr.url, dedupeKey: dedupeKey)
        }
    }

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

    private func persist() {
        let snapshot = state
        DispatchQueue.global(qos: .utility).async { [weak self] in
            try? self?.store.save(snapshot)
        }
    }

    // MARK: - Derived

    var iconState: MenubarIconState {
        if setup.pendingStep != nil { return .setup }
        // First poll hasn't landed yet — don't claim inbox-zero when we just haven't looked.
        if lastCheckedAt == nil && !inErrorState { return .loading }
        if inErrorState { return .error }
        if triageRows.isEmpty { return .idle }
        let counts = Dictionary(grouping: triageRows, by: \.state).mapValues(\.count)
        let buckets = counts
            .map { MenubarBucket(state: $0.key, count: $0.value) }
            .sorted { $0.state.labelPriority < $1.state.labelPriority }
        return .active(buckets: buckets)
    }

    // MARK: - Error state

    private func updateErrorStateAndCause(outcome: PollOutcome) {
        let tickFailed = outcome.error != nil

        if tickFailed {
            consecutiveSuccesses = 0
            inErrorState = true
            appCause = mapCause(error: outcome.error)
        } else {
            consecutiveSuccesses += 1
            if consecutiveSuccesses >= 2 {
                inErrorState = false
                appCause = nil
            }
        }
    }

    private func mapCause(error: GHError?) -> AppCause? {
        guard let err = error else { return nil }
        switch err {
        case .notSignedIn: return .notSignedIn
        case .rateLimited(let at): return .rateLimited(resetAt: at)
        case .networkUnavailable: return .networkUnavailable
        case .insufficientScope: return .insufficientScope
        case .parseError: return .parseError
        case .notInstalled: return .notSignedIn
        case .notFound, .other: return nil
        }
    }

    func retryNow() {
        poller.pokeNow()
    }

    // MARK: - Hide / unhide

    /// Persistently hide a PR from the triage queue. Stays hidden across polls and app
    /// restarts. Auto-clears when the PR is merged/closed (drops from search results).
    func hidePR(id: String) {
        guard !state.hiddenPRs.contains(id) else { return }
        state.hiddenPRs.insert(id)
        triageRows.removeAll { $0.id == id }
        persist()
    }

    /// Restore every hidden PR. The next tick repopulates rows for any still in the queue.
    func unhideAll() {
        guard !state.hiddenPRs.isEmpty else { return }
        state.hiddenPRs.removeAll()
        persist()
        poller.pokeNow()
    }

    var hiddenCount: Int { state.hiddenPRs.count }

    func acknowledgeCorruptedState(path: String) {
        appCause = .corruptedState(path: path)
        inErrorState = true
    }

    func resetCorruptedState() {
        state = AppState()
        appCause = nil
        inErrorState = false
        persist()
        poller.pokeNow()
    }
}
