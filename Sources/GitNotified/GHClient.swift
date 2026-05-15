import Foundation

enum GHError: Error, LocalizedError {
    case notInstalled
    case notSignedIn(message: String)
    case networkUnavailable
    case rateLimited(resetAt: Date?)
    case insufficientScope
    case parseError(String)
    case other(exitCode: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "gh CLI not found in this app's environment"
        case .notSignedIn(let m): return "Not signed in to GitHub: \(m)"
        case .networkUnavailable: return "Network unavailable"
        case .rateLimited(let r): return "GitHub rate limit exceeded\(r.map { " (resets \($0))" } ?? "")"
        case .insufficientScope: return "gh token has insufficient scope"
        case .parseError(let m): return "Could not read GitHub response: \(m)"
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
        return .other(exitCode: result.exitCode, stderr: result.stderr.isEmpty ? result.stdout : result.stderr)
    }

    private func jsonDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }
}
