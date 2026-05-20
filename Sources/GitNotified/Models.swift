import Foundation

enum RepoMode: String, Codable, CaseIterable, Identifiable {
    case off, participating, all
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .participating: return "Participating"
        case .all: return "All"
        }
    }
}

struct WatchedRepo: Codable, Identifiable, Hashable {
    var owner: String
    var name: String
    var mode: RepoMode

    var id: String { "\(owner)/\(name)" }
    var slug: String { "\(owner)/\(name)" }
}

enum EventType: String, Codable {
    case reviewRequested = "review_requested"
    case ciState = "ci_state"
    case comment = "comment"
    case review = "review"
}

enum CIConclusion: String, Codable {
    case failing
    case passing
    case inProgress = "in_progress"
    case none
}

struct CIChangeEvent: Codable, Hashable {
    var pr: PullRequestRef
    var newConclusion: CIConclusion
    var failingCheckName: String?
    var eventID: String
}

struct Cursor: Codable, Equatable {
    var updatedAt: Date
    var eventID: String

    static let zero = Cursor(updatedAt: .distantPast, eventID: "")

    func isNewer(than updatedAt: Date, id: String) -> Bool {
        if updatedAt > self.updatedAt { return true }
        if updatedAt == self.updatedAt { return id > self.eventID }
        return false
    }
}

struct PullRequestRef: Codable, Hashable {
    var owner: String
    var name: String
    var number: Int
    var title: String
    var url: String
    /// GitHub login of the PR author. Nil for older cached refs or PRs whose search
    /// payload didn't include an author (rare — typically suspended/deleted users).
    var authorLogin: String? = nil

    var slug: String { "\(owner)/\(name)" }
    var displayRef: String { "\(slug)#\(number)" }
}

struct ReviewRequest: Codable, Hashable {
    var pr: PullRequestRef
    var requestedAt: Date
    var requester: String?
    var eventID: String
}

struct DropdownRow: Identifiable, Hashable {
    let id: String
    let pr: PullRequestRef
    let summary: String
    let age: String
    let url: String
    var sortKey: Date = .distantPast
}

struct AppState: Codable {
    // Legacy fields — retained for safe rollback. Not written to on the new triage path,
    // but tolerated on read so existing state.json files load cleanly.
    var repos: [WatchedRepo] = []
    var cursors: [String: Cursor] = [:]
    var initializedRepos: Set<String> = []
    var dismissedRowIDs: Set<String> = []

    /// Triage-queue cursors keyed by `"owner/repo#NNNN"`. Each entry stores the set of
    /// active triage states at the previous poll; the next poll diffs against this set
    /// to determine which states are newly active and should fire OS notifications.
    /// A PR absent from this map is "first-observed" and seeds silently.
    var triageCursors: [String: TriagePRCursor] = [:]

    /// PRs explicitly hidden by the user via the row context menu. Suppressed from the
    /// dropdown and from OS notifications. Cleared only by the user via the "Show N hidden"
    /// footer — never auto-pruned, because transient absence from search results would
    /// otherwise un-hide a PR on its next reappearance. Keyed by `"owner/repo#NNNN"`.
    var hiddenPRs: Set<String> = []

    static func cursorKey(repo: WatchedRepo, prNumber: Int, type: EventType) -> String {
        "\(repo.slug)#\(prNumber):\(type.rawValue)"
    }

    static func triageKey(owner: String, name: String, number: Int) -> String {
        "\(owner)/\(name)#\(number)"
    }

    init(repos: [WatchedRepo] = [],
         cursors: [String: Cursor] = [:],
         initializedRepos: Set<String> = [],
         dismissedRowIDs: Set<String> = [],
         triageCursors: [String: TriagePRCursor] = [:],
         hiddenPRs: Set<String> = []) {
        self.repos = repos
        self.cursors = cursors
        self.initializedRepos = initializedRepos
        self.dismissedRowIDs = dismissedRowIDs
        self.triageCursors = triageCursors
        self.hiddenPRs = hiddenPRs
    }

    enum CodingKeys: String, CodingKey { case repos, cursors, initializedRepos, dismissedRowIDs, triageCursors, hiddenPRs }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.repos = (try? c.decode([WatchedRepo].self, forKey: .repos)) ?? []
        self.cursors = (try? c.decode([String: Cursor].self, forKey: .cursors)) ?? [:]
        self.initializedRepos = (try? c.decode(Set<String>.self, forKey: .initializedRepos)) ?? []
        self.dismissedRowIDs = (try? c.decode(Set<String>.self, forKey: .dismissedRowIDs)) ?? []
        self.triageCursors = (try? c.decode([String: TriagePRCursor].self, forKey: .triageCursors)) ?? [:]
        self.hiddenPRs = (try? c.decode(Set<String>.self, forKey: .hiddenPRs)) ?? []
    }
}

struct ActivityEvent: Codable, Hashable {
    enum Kind: String, Codable { case comment, review }
    var kind: Kind
    var pr: PullRequestRef
    var author: String?
    var createdAt: Date
    var url: String
    var eventID: String
    var bodyExcerpt: String?
}

/// Structured error causes surfaced in the dropdown banner. Drawn from a small named set
/// so the UI always has a recognized message + action affordance.
enum AppCause: Equatable {
    case notSignedIn
    case rateLimited(resetAt: Date?)
    case networkUnavailable
    case insufficientScope
    case parseError
    case notificationsDisabled
    case corruptedState(path: String)

    var message: String {
        switch self {
        case .notSignedIn:
            return "Not signed in to GitHub — Run `gh auth login`"
        case .rateLimited(let resetAt):
            if let r = resetAt {
                let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
                return "GitHub rate limit exceeded — Retrying at \(f.string(from: r))"
            }
            return "GitHub rate limit exceeded — Will retry"
        case .networkUnavailable:
            return "Network unavailable — Will retry"
        case .insufficientScope:
            return "gh token has insufficient scope — Run `gh auth login` to re-grant"
        case .parseError:
            return "Could not read GitHub response — gh may have been updated"
        case .notificationsDisabled:
            return "Notifications disabled — Open System Settings"
        case .corruptedState:
            return "Corrupted state file"
        }
    }
}

/// A single failing repository surfaced as a "No access" row in the dropdown instead of
/// its normal sections. Does NOT escalate the global menubar icon to error state.
struct RepoFailure: Equatable {
    enum Cause: String, Equatable { case notFound, accessRevoked, renamedOrTransferred, unknown }
    var slug: String
    var cause: Cause

    var copy: String {
        switch cause {
        case .notFound: return "No access — Repository not found"
        case .accessRevoked: return "No access — Access revoked"
        case .renamedOrTransferred: return "No access — Repository not found — may have been renamed or transferred"
        case .unknown: return "No access"
        }
    }
}

struct ResumeBanner: Equatable {
    let durationMinutes: Int
    let suppressedCount: Int

    var text: String {
        let durationText = ResumeBanner.scale(minutes: durationMinutes)
        return "Silenced for \(durationText) — \(suppressedCount) new \(suppressedCount == 1 ? "item" : "items") below"
    }

    static func scale(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s")" }
        if minutes < 60 * 24 {
            let h = minutes / 60
            return "\(h) hour\(h == 1 ? "" : "s")"
        }
        let d = minutes / (60 * 24)
        return "\(d) day\(d == 1 ? "" : "s")"
    }
}

struct MenubarBucket: Equatable {
    let state: TriageState
    let count: Int
}

enum MenubarIconState: Equatable {
    /// First poll hasn't completed — we don't yet know whether the queue is empty.
    case loading
    case idle
    /// Buckets are sorted by `labelPriority` (most urgent first) and contain only non-empty
    /// states, so every queued PR shows up under its own emoji and count.
    case active(buckets: [MenubarBucket])
    case setup
    case error
}

// MARK: - Triage queue model

enum TriageRole: String, Codable {
    case author      // your PR
    case reviewer    // someone requested your review
}

enum TriageState: String, Codable, Hashable {
    case approved
    case changesRequested
    case ciFailing
    case unansweredComment
    case reviewRequested
    /// Catch-all for your own open non-draft PRs that have no other active triage state.
    /// Surfaces in the dropdown so the queue is always a complete view of your open PRs,
    /// but does not fire OS notifications and does not bump the menu-bar count badge.
    case waitingForReview
    /// A PR you reviewed that is now approved/ready to merge (waiting on the author or
    /// another maintainer to merge). Stays in the reviewer section, sorted to the bottom,
    /// until the PR is merged or closed (at which point it drops out of search results).
    /// Awareness signal only — no notification.
    case reviewedApproved

    /// In-row priority — selects the single label when multiple states are active on one PR.
    /// Lower number wins (highest urgency).
    var labelPriority: Int {
        switch self {
        case .ciFailing: return 1
        case .changesRequested: return 2
        case .unansweredComment: return 3
        case .approved: return 4
        case .reviewRequested: return 5
        case .waitingForReview: return 6
        case .reviewedApproved: return 7
        }
    }

    /// Cross-PR sort order within a section. "Easy wins first" — approvals at top,
    /// CI-failing at the bottom of the actionable set, waiting after that.
    var sortOrder: Int {
        switch self {
        case .approved: return 1
        case .changesRequested: return 2
        case .unansweredComment: return 3
        case .ciFailing: return 4
        case .waitingForReview: return 5
        case .reviewRequested: return 6
        case .reviewedApproved: return 7
        }
    }

    var label: String {
        switch self {
        case .approved: return "Ready to merge"
        case .changesRequested: return "Address feedback"
        case .unansweredComment: return "Respond"
        case .ciFailing: return "Fix CI"
        case .reviewRequested: return "Review"
        case .waitingForReview: return "Waiting for review"
        case .reviewedApproved: return "Approved — ready to ship"
        }
    }

    var glyph: String {
        switch self {
        case .approved: return "checkmark.seal.fill"
        case .changesRequested: return "arrow.uturn.left.circle"
        case .unansweredComment: return "text.bubble"
        case .ciFailing: return "xmark.octagon.fill"
        case .reviewRequested: return "eye.circle"
        case .waitingForReview: return "hourglass"
        case .reviewedApproved: return "checkmark.seal"
        }
    }

    /// Emoji surfaced in the menu bar when this state is the top non-empty bucket.
    var menubarEmoji: String {
        switch self {
        case .ciFailing: return "🚨"
        case .changesRequested: return "📝"
        case .unansweredComment: return "💬"
        case .approved: return "✅"
        case .reviewRequested: return "👀"
        case .waitingForReview: return "⏳"
        case .reviewedApproved: return "✅"
        }
    }

    /// The TriageState used to bucket this row in the menubar title. Most states bucket
    /// as themselves; `reviewedApproved` rolls up under `approved` so the title shows a
    /// single ✅ segment covering both "my PR is ready to merge" and "PR I reviewed is
    /// approved" rather than two adjacent ✅ counts.
    var menubarBucket: TriageState {
        switch self {
        case .reviewedApproved: return .approved
        default: return self
        }
    }

    /// Whether this state should fire an OS notification when it newly activates and
    /// whether it should contribute to the menu-bar count badge. `waitingForReview` is
    /// an awareness signal only — it doesn't ding you, and you've already implicitly
    /// "acted" on it by opening the PR. `reviewedApproved` is similarly informational —
    /// the merge action belongs to someone else.
    var isActionable: Bool {
        self != .waitingForReview && self != .reviewedApproved
    }
}

/// Per-PR aggregation produced by a poll. Carries the full state set (used for cursor
/// diffing and OS notifications) plus the single label selected for the row.
struct TriagePR: Hashable {
    let pr: PullRequestRef
    let role: TriageRole
    let isDraft: Bool
    let states: Set<TriageState>
    let prUpdatedAt: Date
    /// Diff size + CI rollup state from GraphQL. Authored PRs read it from `prDetail`;
    /// reviewer PRs get it from a single batched `prRowExtras` request so neither path
    /// adds an N+1.
    let additions: Int?
    let deletions: Int?
    let ciState: String?

    /// The state that drives the row's displayed label (lowest labelPriority).
    var primaryState: TriageState? {
        states.min(by: { $0.labelPriority < $1.labelPriority })
    }
}

/// View-model row. Stable id is `"owner/repo#NNNN"` so SwiftUI animates updates.
struct TriageRow: Identifiable, Hashable {
    let id: String
    let role: TriageRole
    let pr: PullRequestRef
    let state: TriageState
    let age: String
    let sortKey: Date
    let additions: Int?
    let deletions: Int?
    let ciState: String?
}

/// Persisted per-PR triage cursor. Stores the set of states active at the most recent poll
/// so the next poll can diff against it and fire notifications only for newly-active states.
struct TriagePRCursor: Codable, Equatable {
    var states: Set<TriageState>
    var lastSeenAt: Date
}

