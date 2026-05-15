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
}

struct AppState: Codable {
    var repos: [WatchedRepo] = []
    var cursors: [String: Cursor] = [:]

    static func cursorKey(repo: WatchedRepo, prNumber: Int, type: EventType) -> String {
        "\(repo.slug)#\(prNumber):\(type.rawValue)"
    }
}

enum MenubarIconState: Equatable {
    case idle
    case active(count: Int)
    case setup
    case error
}
