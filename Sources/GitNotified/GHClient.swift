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

// MARK: - Triage-shaped result types

/// PR returned by `gh search prs --json number,title,url,updatedAt,isDraft,author,repository`.
struct GHSearchPR: Decodable, Hashable {
    let number: Int
    let title: String
    let url: String
    let updatedAt: Date
    let isDraft: Bool
    let author: GHPRListing.GHAuthor?
    let repository: GHSearchRepoRef

    struct GHSearchRepoRef: Decodable, Hashable {
        let name: String
        let nameWithOwner: String
    }

    var owner: String {
        repository.nameWithOwner.split(separator: "/").first.map(String.init) ?? ""
    }
}

/// Detail fetched per PR. Pulled via GraphQL (not `gh pr view --json`) because we need
/// the aggregate `statusCheckRollup.state` — the same field GitHub uses to render the
/// PR's green/yellow/red dot — and the CLI's JSON only exposes the flat check list.
/// Without the aggregate, a non-blocking advisory check like `check_pr_title` would
/// surface as Fix CI even though required checks all pass.
struct GHPRDetail {
    let reviewDecision: String?       // APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED, or null
    let mergeStateStatus: String?     // CLEAN, UNSTABLE, BLOCKED, BEHIND, DIRTY, DRAFT, HAS_HOOKS, UNKNOWN
    /// Aggregate rollup of the last commit's required checks: SUCCESS, PENDING, FAILURE, ERROR, or nil if absent.
    let ciAggregateState: String?
    let additions: Int?
    let deletions: Int?
    let commits: [GHCommitEntry]

    struct GHCommitEntry: Hashable {
        let committedDate: Date?
        let authorLogins: [String]
    }
}

/// Wraps the `gh` CLI. All calls are synchronous; callers must dispatch off the main thread.
final class GHClient {
    private let executableSearchPaths = [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh",
        "/usr/bin/gh",
    ]

    /// Cached `gh api user` login, looked up lazily. Used to identify "my" comments and
    /// commits during triage-state derivation.
    private var cachedLogin: String?

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

    /// Detects whether `gh` exists somewhere on the user's interactive shell PATH but is
    /// not reachable from the app's runtime environment. Used to distinguish the spec's
    /// "Install gh" copy from the "gh not found in this app's environment" copy when the
    /// app is launched as a Login Item with a minimal PATH (F4).
    func detectInstalledButNotReachable() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-lic", "command -v gh || true"]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return !out.isEmpty
        } catch {
            return false
        }
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

    // MARK: - Triage-shaped queries

    /// Global search for open PRs you authored. Used by the triage queue's "Yours" section.
    func searchAuthoredPRs() throws -> [GHSearchPR] {
        try searchPRs(extraFlags: ["--author=@me"])
    }

    /// Global search for open PRs awaiting your review. Used by the "Reviews requested" section.
    func searchReviewRequestedPRs() throws -> [GHSearchPR] {
        try searchPRs(extraFlags: ["--review-requested=@me"])
    }

    private func searchPRs(extraFlags: [String]) throws -> [GHSearchPR] {
        var args = [
            "search", "prs",
            "--state=open",
            "--archived=false",
            "--limit", "200",
            "--json", "number,title,url,updatedAt,isDraft,author,repository",
        ]
        args.append(contentsOf: extraFlags)
        let result = try run(args)
        guard result.exitCode == 0 else { throw classify(result) }
        do {
            return try jsonDecoder().decode([GHSearchPR].self, from: Data(result.stdout.utf8))
        } catch {
            throw GHError.parseError("search prs: \(error.localizedDescription)")
        }
    }

    /// Per-PR detail fetch via GraphQL. Returns the fields needed to derive triage states,
    /// including the aggregate `statusCheckRollup.state` from the last commit (the one GitHub
    /// uses to render its merge button state).
    func prDetail(owner: String, name: String, number: Int) throws -> GHPRDetail {
        let query = """
        query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              reviewDecision
              mergeStateStatus
              additions
              deletions
              lastCommit: commits(last: 1) {
                nodes { commit { statusCheckRollup { state } } }
              }
              commits(last: 100) {
                nodes {
                  commit {
                    committedDate
                    authors(first: 5) { nodes { user { login } } }
                  }
                }
              }
            }
          }
        }
        """
        let result = try run([
            "api", "graphql",
            "-f", "query=\(query)",
            "-F", "owner=\(owner)",
            "-F", "name=\(name)",
            "-F", "number=\(number)",
        ])
        guard result.exitCode == 0 else { throw classify(result) }
        guard let data = result.stdout.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataRoot = root["data"] as? [String: Any],
              let repo = dataRoot["repository"] as? [String: Any],
              let pr = repo["pullRequest"] as? [String: Any]
        else { throw GHError.parseError("graphql pr detail \(owner)/\(name)#\(number)") }

        let reviewDecision = pr["reviewDecision"] as? String
        let mergeStateStatus = pr["mergeStateStatus"] as? String
        let additions = pr["additions"] as? Int
        let deletions = pr["deletions"] as? Int
        var aggregateState: String? = nil
        if let last = pr["lastCommit"] as? [String: Any],
           let nodes = last["nodes"] as? [[String: Any]],
           let commit = nodes.first?["commit"] as? [String: Any],
           let rollup = commit["statusCheckRollup"] as? [String: Any] {
            aggregateState = rollup["state"] as? String
        }

        var commits: [GHPRDetail.GHCommitEntry] = []
        if let commitsObj = pr["commits"] as? [String: Any],
           let nodes = commitsObj["nodes"] as? [[String: Any]]
        {
            let iso = ISO8601DateFormatter()
            for n in nodes {
                guard let commit = n["commit"] as? [String: Any] else { continue }
                let date = (commit["committedDate"] as? String).flatMap { iso.date(from: $0) }
                var logins: [String] = []
                if let authors = commit["authors"] as? [String: Any],
                   let aNodes = authors["nodes"] as? [[String: Any]]
                {
                    for a in aNodes {
                        if let user = a["user"] as? [String: Any], let login = user["login"] as? String {
                            logins.append(login)
                        }
                    }
                }
                commits.append(GHPRDetail.GHCommitEntry(committedDate: date, authorLogins: logins))
            }
        }

        return GHPRDetail(
            reviewDecision: reviewDecision,
            mergeStateStatus: mergeStateStatus,
            ciAggregateState: aggregateState,
            additions: additions,
            deletions: deletions,
            commits: commits
        )
    }

    /// Batched diff-size fetch for a list of PRs. One GraphQL request returns
    /// `additions`/`deletions` for every PR via aliased `repository` sub-queries, so we
    /// avoid an N+1 over reviewer-role PRs (which otherwise have no per-PR detail call).
    /// Returned map keys are `"owner/name#number"`. Missing or null entries are omitted.
    /// GitHub repo + owner names are restricted to `[A-Za-z0-9._-]`, so direct
    /// interpolation into the GraphQL string is safe — no quotes to escape.
    func prDiffSizes(refs: [(owner: String, name: String, number: Int)]) throws -> [String: (additions: Int, deletions: Int)] {
        guard !refs.isEmpty else { return [:] }
        let aliases = refs.enumerated().map { idx, ref in
            "pr\(idx): repository(owner: \"\(ref.owner)\", name: \"\(ref.name)\") { pullRequest(number: \(ref.number)) { additions deletions } }"
        }.joined(separator: "\n  ")
        let query = "query {\n  \(aliases)\n}"
        let result = try run(["api", "graphql", "-f", "query=\(query)"])
        guard result.exitCode == 0 else { throw classify(result) }
        guard let data = result.stdout.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataRoot = root["data"] as? [String: Any]
        else { throw GHError.parseError("graphql pr diff sizes") }
        var out: [String: (additions: Int, deletions: Int)] = [:]
        for (idx, ref) in refs.enumerated() {
            guard let repo = dataRoot["pr\(idx)"] as? [String: Any],
                  let pr = repo["pullRequest"] as? [String: Any],
                  let a = pr["additions"] as? Int,
                  let d = pr["deletions"] as? Int
            else { continue }
            out["\(ref.owner)/\(ref.name)#\(ref.number)"] = (a, d)
        }
        return out
    }

    /// Returns the current GitHub user's login, looked up via `gh api user` and cached for the
    /// lifetime of this GHClient. Used by triage logic to recognize "my" comments and commits.
    func currentUserLogin() throws -> String {
        if let login = cachedLogin { return login }
        let result = try run(["api", "user", "--jq", ".login"])
        guard result.exitCode == 0 else { throw classify(result) }
        let login = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !login.isEmpty else { throw GHError.parseError("empty login from `gh api user`") }
        cachedLogin = login
        return login
    }

    /// All issue comments on a PR (no `since` filter — triage needs full history to determine
    /// "unanswered" state). Lighter wrapper around the existing pagination call.
    func listAllPRIssueComments(owner: String, name: String, number: Int) throws -> [GHIssueComment] {
        let result = try run([
            "api", "--paginate",
            "repos/\(owner)/\(name)/issues/\(number)/comments?per_page=100",
        ])
        guard result.exitCode == 0 else { throw classify(result) }
        do {
            return try jsonDecoder().decode([GHIssueComment].self, from: Data(result.stdout.utf8))
        } catch {
            throw GHError.parseError("comments: \(error.localizedDescription)")
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

        // Drain both pipes on background queues before waiting for exit. If the child writes
        // more than the OS pipe buffer (~64KB) and nobody is reading, it blocks on stdout/stderr
        // forever and waitUntilExit() never returns — freezing the serial poller queue.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let q = DispatchQueue.global(qos: .userInitiated)
        group.enter()
        q.async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        q.async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        proc.waitUntilExit()
        group.wait()

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
