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
    var repos: [WatchedRepo] = []
    var cursors: [String: Cursor] = [:]
    /// Repos whose first observation has been recorded — used to honor the
    /// no-backfill-on-add rule. A repo absent from this set is treated as fresh:
    /// its initial poll seeds cursors but suppresses notification firing.
    var initializedRepos: Set<String> = []
    /// Dropdown row IDs the user has explicitly dismissed via "Clear". Filtered out of
    /// snapshots until the row's underlying event ages out of the activity window, at
    /// which point the ID is pruned. This is dropdown-only — the notification path is
    /// unaffected (cursors govern what gets notified).
    var dismissedRowIDs: Set<String> = []

    static func cursorKey(repo: WatchedRepo, prNumber: Int, type: EventType) -> String {
        "\(repo.slug)#\(prNumber):\(type.rawValue)"
    }

    init(repos: [WatchedRepo] = [], cursors: [String: Cursor] = [:], initializedRepos: Set<String> = [], dismissedRowIDs: Set<String> = []) {
        self.repos = repos
        self.cursors = cursors
        self.initializedRepos = initializedRepos
        self.dismissedRowIDs = dismissedRowIDs
    }

    enum CodingKeys: String, CodingKey { case repos, cursors, initializedRepos, dismissedRowIDs }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.repos = (try? c.decode([WatchedRepo].self, forKey: .repos)) ?? []
        self.cursors = (try? c.decode([String: Cursor].self, forKey: .cursors)) ?? [:]
        self.initializedRepos = (try? c.decode(Set<String>.self, forKey: .initializedRepos)) ?? []
        self.dismissedRowIDs = (try? c.decode(Set<String>.self, forKey: .dismissedRowIDs)) ?? []
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

enum MenubarIconState: Equatable {
    case idle
    case active(count: Int)
    case setup
    case error
}
