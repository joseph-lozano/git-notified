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
    @Published var showingAddRepo: Bool = false

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
        poller.onTick = { [weak self] outcome in
            self?.handleTick(outcome)
        }
    }

    func bootstrap() {
        notifications.requestAuthorization()
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
        state.initializedRepos.formUnion(outcome.reposInitialized)
        let stateMutated = !outcome.cursorsToSet.isEmpty
            || !outcome.cursorsToClear.isEmpty
            || !outcome.reposInitialized.isEmpty
        if stateMutated { persist() }

        reviewRows = outcome.reviewsRequestedSnapshot
        ciFailingRows = outcome.ciFailingSnapshot
        activityRows = outcome.activitySnapshot
        lastCheckedAt = outcome.lastCheckedAt
        lastError = outcome.error

        for ev in outcome.newReviewRequests {
            let title: String
            if let r = ev.requester {
                title = "Review requested by @\(r)"
            } else {
                title = "Review requested"
            }
            let subtitle = "\(ev.pr.displayRef) — \(ev.pr.title)"
            notifications.post(
                title: title,
                subtitle: subtitle,
                url: ev.pr.url,
                dedupeKey: ev.eventID
            )
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
            notifications.post(
                title: title,
                subtitle: subtitle,
                url: ev.url,
                dedupeKey: ev.eventID
            )
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
            notifications.post(
                title: title,
                subtitle: subtitle,
                url: ev.pr.url,
                dedupeKey: ev.eventID
            )
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
        if lastError != nil { return .error }
        let count = reviewRows.count + ciFailingRows.count + activityRows.count
        return count == 0 ? .idle : .active(count: count)
    }
}
