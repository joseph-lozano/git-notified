import Foundation

enum GHError: Error, LocalizedError {
    case notInstalled
    case notSignedIn(message: String)
    case networkUnavailable
    case rateLimited(resetAt: Date?)
    case insufficientScope
    case parseError(String)
    case notFound
    case other(exitCode: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "gh CLI not found in this app's environment"
        case .notSignedIn(let m): return "Not signed in to GitHub: \(m)"
        case .networkUnavailable: return "Network unavailable"
        case .rateLimited(let r): return "GitHub rate limit exceeded\(r.map { " (resets \($0))" } ?? "")"
        case .insufficientScope: return "gh token has insufficient scope"
        case .parseError(let m): return "Could not read GitHub response: \(m)"
        case .notFound: return "Repository not found or access revoked"
        case .other(_, let s): return s
        }
    }
}

struct GHRepoListing: Decodable, Hashable {
    let owner: GHOwnerRef
    let name: String
    let nameWithOwner: String

    struct GHOwnerRef: Decodable, Hashable {
        let login: String
    }
}

/// PR row from `gh pr list --json`. Matches the JSON shape produced by gh.
struct GHPRListing: Decodable, Hashable {
    let number: Int
    let title: String
    let url: String
    let updatedAt: Date
    let author: GHAuthor?

    struct GHAuthor: Decodable, Hashable {
        let login: String?
    }
}

/// PR row including CI rollup. statusCheckRollup mixes CheckRun and StatusContext shapes;
/// we decode only the conclusion-relevant fields and tolerate either.
struct GHPRWithCI: Decodable, Hashable {
    let number: Int
    let title: String
    let url: String
    let updatedAt: Date
    let author: GHPRListing.GHAuthor?
    let statusCheckRollup: [GHCheckEntry]?

    struct GHCheckEntry: Decodable, Hashable {
        let name: String?
        let conclusion: String?   // CheckRun: SUCCESS, FAILURE, CANCELLED, TIMED_OUT, NEUTRAL, SKIPPED, STALE
        let status: String?       // CheckRun: QUEUED, IN_PROGRESS, COMPLETED
        let state: String?        // StatusContext: SUCCESS, ERROR, FAILURE, PENDING
    }

    var ciConclusion: CIConclusion {
        guard let rollup = statusCheckRollup, !rollup.isEmpty else {
            return .none
        }
        var anyFailing = false
        var anyInProgress = false
        for entry in rollup {
            if let c = entry.conclusion?.uppercased() {
                switch c {
                case "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE":
                    anyFailing = true
                case "SUCCESS", "NEUTRAL", "SKIPPED", "STALE":
                    break
                default:
                    anyInProgress = true
                }
            } else if let s = entry.state?.uppercased() {
                switch s {
                case "FAILURE", "ERROR":
                    anyFailing = true
                case "SUCCESS":
                    break
                case "PENDING":
                    anyInProgress = true
                default:
                    anyInProgress = true
                }
            } else if let st = entry.status?.uppercased(), st != "COMPLETED" {
                anyInProgress = true
            }
        }
        if anyFailing { return .failing }
        if anyInProgress { return .inProgress }
        return .passing
    }

    var failingCheckName: String? {
        statusCheckRollup?.first(where: {
            let c = ($0.conclusion ?? "").uppercased()
            let s = ($0.state ?? "").uppercased()
            return ["FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "ERROR"].contains(c)
                || ["FAILURE", "ERROR"].contains(s)
        })?.name
    }
}


struct GHIssueComment: Decodable, Hashable {
    let id: Int
    let user: GHUserRef?
    let created_at: Date
    let html_url: String
    let body: String?

    struct GHUserRef: Decodable, Hashable { let login: String? }
}

struct GHReview: Decodable, Hashable {
    let id: Int
    let user: GHIssueComment.GHUserRef?
    let state: String?           // APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED, PENDING
    let submitted_at: Date?
    let html_url: String
    let body: String?
}

/// Wraps the `gh` CLI. All calls are synchronous; callers must dispatch off the main thread.
final class GHClient {
    private let executableSearchPaths = [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh",
        "/usr/bin/gh",
    ]

    func locateExecutable() -> String? {
        if let env = ProcessInfo.processInfo.environment["PATH"] {
            for dir in env.split(separator: ":") {
                let candidate = "\(dir)/gh"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return executableSearchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Returns true if `gh auth status` reports a signed-in user.
    /// Throws .networkUnavailable for network-style errors so callers can distinguish.
    func checkAuth() throws -> Bool {
        let result = try run(["auth", "status"])
        if result.exitCode == 0 { return true }
        let combined = (result.stderr + result.stdout).lowercased()
        if combined.contains("not logged") || combined.contains("not authenticated") {
            return false
        }
        if combined.contains("could not resolve") || combined.contains("network") || combined.contains("timeout") {
            throw GHError.networkUnavailable
        }
        return false
    }

    func listRepos(limit: Int = 100) throws -> [GHRepoListing] {
        let result = try run([
            "repo", "list",
            "--limit", String(limit),
            "--json", "owner,name,nameWithOwner",
        ])
        guard result.exitCode == 0 else {
            throw classify(result)
        }
        do {
            return try jsonDecoder().decode([GHRepoListing].self, from: Data(result.stdout.utf8))
        } catch {
            throw GHError.parseError(error.localizedDescription)
        }
    }

    /// Lists open PRs in a repo within the given scope (participating uses `involves:@me`;
    /// all returns every open PR) with each PR's status-check rollup so the caller can
    /// derive aggregate CI conclusion per PR.
    func listPRsWithCI(owner: String, name: String, scope: RepoMode) throws -> [GHPRWithCI] {
        var args = [
            "pr", "list",
            "--repo", "\(owner)/\(name)",
            "--state", "open",
            "--limit", "200",
            "--json", "number,title,url,updatedAt,author,statusCheckRollup",
        ]
        if scope == .participating {
            args.append(contentsOf: ["--search", "involves:@me"])
        }
        let result = try run(args)
        guard result.exitCode == 0 else { throw classify(result) }
        do {
            return try jsonDecoder().decode([GHPRWithCI].self, from: Data(result.stdout.utf8))
        } catch {
            throw GHError.parseError(error.localizedDescription)
        }
    }

    /// Issue comments on a PR (PR comments are issue comments in GitHub's data model).
    /// Returns all pages by following gh's --paginate behavior.
    func listPRIssueComments(owner: String, name: String, number: Int, since: Date) throws -> [GHIssueComment] {
        let sinceISO = ISO8601DateFormatter().string(from: since)
        let result = try run([
            "api", "--paginate",
            "repos/\(owner)/\(name)/issues/\(number)/comments?since=\(sinceISO)&per_page=100",
        ])
        guard result.exitCode == 0 else { throw classify(result) }
        do {
            return try jsonDecoder().decode([GHIssueComment].self, from: Data(result.stdout.utf8))
        } catch {
            throw GHError.parseError("comments: \(error.localizedDescription)")
        }
    }

    /// Reviews on a PR. The REST endpoint does not accept `since`; we fetch and filter client-side.
    func listPRReviews(owner: String, name: String, number: Int) throws -> [GHReview] {
        let result = try run([
            "api", "--paginate",
            "repos/\(owner)/\(name)/pulls/\(number)/reviews?per_page=100",
        ])
        guard result.exitCode == 0 else { throw classify(result) }
        do {
            return try jsonDecoder().decode([GHReview].self, from: Data(result.stdout.utf8))
        } catch {
            throw GHError.parseError("reviews: \(error.localizedDescription)")
        }
    }

    /// Lists open PRs in a repo where the current user is a requested reviewer.
    /// Fetches every page; gh paginates with --limit.
    func listReviewRequestedPRs(owner: String, name: String) throws -> [GHPRListing] {
        let result = try run([
            "pr", "list",
            "--repo", "\(owner)/\(name)",
            "--search", "review-requested:@me",
            "--state", "open",
            "--limit", "200",
            "--json", "number,title,url,updatedAt,author",
        ])
        guard result.exitCode == 0 else {
            throw classify(result)
        }
        do {
            return try jsonDecoder().decode([GHPRListing].self, from: Data(result.stdout.utf8))
        } catch {
            throw GHError.parseError(error.localizedDescription)
        }
    }

    // MARK: - Private

    private struct RunResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private func run(_ args: [String]) throws -> RunResult {
        guard let exec = locateExecutable() else { throw GHError.notInstalled }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exec)
        proc.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        try proc.run()
        proc.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return RunResult(
            exitCode: proc.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    private func classify(_ result: RunResult) -> GHError {
        let combined = (result.stderr + result.stdout).lowercased()
        if combined.contains("rate limit") || combined.contains("api rate limit exceeded") {
            return .rateLimited(resetAt: nil)
        }
        if combined.contains("not logged") || combined.contains("not authenticated") {
            return .notSignedIn(message: result.stderr)
        }
        if combined.contains("could not resolve") || combined.contains("network is unreachable") || combined.contains("timeout") {
            return .networkUnavailable
        }
        if combined.contains("must have") && combined.contains("scope") {
            return .insufficientScope
        }
        if combined.contains("404") || combined.contains("not found") || combined.contains("could not resolve to a repository") {
            return .notFound
        }
        return .other(exitCode: result.exitCode, stderr: result.stderr.isEmpty ? result.stdout : result.stderr)
    }

    private func jsonDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }
}
