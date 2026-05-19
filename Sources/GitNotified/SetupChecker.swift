import Foundation

enum SetupStep: Equatable {
    case installGh
    case ghNotReachable    // installed somewhere on user PATH but not in app's runtime PATH (F4)
    case signIn

    var label: String {
        switch self {
        case .installGh: return "Install gh"
        case .ghNotReachable: return "`gh` not found in this app's environment"
        case .signIn: return "Sign in with `gh auth login`"
        }
    }
}

struct SetupStatus: Equatable {
    var ghInstalled: Bool
    var ghReachable: Bool
    var signedIn: Bool
    var authNetworkError: Bool
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
        let ghReachable = gh.locateExecutable() != nil
        var ghInstalled = ghReachable
        if !ghReachable {
            // F4: if gh is installed but not on the app's PATH, surface a distinct copy.
            ghInstalled = gh.detectInstalledButNotReachable()
        }

        var signedIn = false
        var authNetworkError = false
        if ghReachable {
            do {
                signedIn = try gh.checkAuth()
            } catch GHError.networkUnavailable {
                authNetworkError = true
            } catch {
                signedIn = false
            }
        }
        _ = state  // legacy parameter retained for call-site stability; no per-repo step in the triage model.

        // F13: a network error on auth-check is an error-state condition, not a setup-state one.
        // Surface as no pending step so AppModel can route into AppCause.networkUnavailable instead.
        let pending: SetupStep? = {
            if authNetworkError { return nil }
            if !ghReachable && ghInstalled { return .ghNotReachable }
            if !ghReachable { return .installGh }
            if !signedIn { return .signIn }
            return nil
        }()

        return SetupStatus(
            ghInstalled: ghInstalled,
            ghReachable: ghReachable,
            signedIn: signedIn,
            authNetworkError: authNetworkError,
            pendingStep: pending
        )
    }
}
