import Foundation

enum SetupStep: Equatable {
    case installGh
    case signIn
    case addRepo

    var label: String {
        switch self {
        case .installGh: return "Install gh"
        case .signIn: return "Sign in with `gh auth login`"
        case .addRepo: return "Add a repository"
        }
    }
}

struct SetupStatus: Equatable {
    var ghInstalled: Bool
    var signedIn: Bool
    var hasRepo: Bool
    var pendingStep: SetupStep?

    var isComplete: Bool { pendingStep == nil }
}

final class SetupChecker {
    private let gh: GHClient

    init(gh: GHClient) {
        self.gh = gh
    }

    /// Synchronous check; callers should run off the main thread.
    func evaluate(state: AppState) -> SetupStatus {
        let ghInstalled = gh.locateExecutable() != nil
        var signedIn = false
        if ghInstalled {
            // checkAuth throws .networkUnavailable for network-style errors; treat as "not signed in"
            // for setup purposes — Phase 6/7 will route network failures into the error state instead.
            signedIn = (try? gh.checkAuth()) ?? false
        }
        let hasRepo = state.repos.contains { $0.mode != .off }

        let pending: SetupStep? = {
            if !ghInstalled { return .installGh }
            if !signedIn { return .signIn }
            if !hasRepo { return .addRepo }
            return nil
        }()

        return SetupStatus(
            ghInstalled: ghInstalled,
            signedIn: signedIn,
            hasRepo: hasRepo,
            pendingStep: pending
        )
    }
}
