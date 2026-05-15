import SwiftUI
import AppKit

@main
struct GitNotifiedApp: App {
    @StateObject private var model: AppModel = {
        // Single-instance enforcement (D20, F5): if another instance with the same bundle
        // identifier is already running on this Mac, activate it and exit. This makes the
        // Login Item + manual launch case safe by default.
        if let bundleID = Bundle.main.bundleIdentifier {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if let other = running.first {
                other.activate(options: [])
                exit(0)
            }
        }

        let gh = GHClient()
        let store: Store
        do {
            store = try Store()
        } catch {
            fatalError("Could not initialize Store: \(error.localizedDescription)")
        }
        return AppModel(store: store, gh: gh)
    }()

    var body: some Scene {
        MenuBarExtra {
            DropdownView()
                .environmentObject(model)
                .frame(width: 360)
                .onAppear { model.bootstrap() }
        } label: {
            MenubarLabel(state: model.iconState)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenubarLabel: View {
    let state: MenubarIconState

    var body: some View {
        content
            .accessibilityLabel(accessibleLabel)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            Image(systemName: "bell")
        case .active(let count):
            HStack(spacing: 2) {
                Image(systemName: "bell.fill")
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
            }
        case .setup:
            // Neutral, additive overlay — distinct from the reactive error icon.
            Image(systemName: "bell.badge.plus")
        case .error:
            // Reactive, attention-grabbing overlay — distinct from the additive setup icon.
            Image(systemName: "bell.badge.fill")
                .foregroundStyle(.red)
        }
    }

    /// State-inclusive accessible labels per spec's Accessibility section.
    private var accessibleLabel: String {
        switch state {
        case .idle: return "git-notified, no outstanding items"
        case .active(let n): return "git-notified, \(n) outstanding \(n == 1 ? "item" : "items")"
        case .setup: return "git-notified, setup required"
        case .error: return "git-notified, error"
        }
    }
}
