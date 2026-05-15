import SwiftUI
import AppKit
import Combine

@main
struct GitNotifiedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // We host the menubar icon via NSStatusItem in AppDelegate; the SwiftUI Settings
        // scene here is just a placeholder so the App protocol is satisfied without
        // creating any visible window.
        Settings { EmptyView() }
    }
}

/// AppKit-backed menubar host. We use NSStatusItem + NSPopover instead of SwiftUI's
/// `MenuBarExtra` because the latter has rendering gaps on some macOS Tahoe (16+)
/// builds where the scene creates no visible status item.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var cancellableObserver: NSObjectProtocol?
    private var iconObservation: AnyCancellable?

    override init() {
        // Single-instance enforcement (D20, F5): bail before constructing state if a
        // running peer with the same bundle id exists.
        if let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if let other = others.first {
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
        self.model = AppModel(store: store, gh: gh)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Build the status item with a guaranteed-visible title — text first so the icon
        // is unambiguously present even before SF Symbol rendering kicks in.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "GN"
            button.image = NSImage(systemSymbolName: "bell", accessibilityDescription: "git-notified")
            button.imagePosition = .imageLeading
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        // Popover hosts the SwiftUI DropdownView. .transient closes on outside-click.
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 380, height: 480)
        popover.contentViewController = NSHostingController(
            rootView: DropdownView().environmentObject(model)
        )

        // Reflect iconState changes (counts, error, setup) into the status-item title.
        iconObservation = Publishers.CombineLatest4(
            model.$reviewRows,
            model.$ciFailingRows,
            model.$commentRows,
            model.$reviewSubmissionRows
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _, _, _, _ in
            self?.refreshStatusItemLabel()
        }
        refreshStatusItemLabel()

        model.bootstrap()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func refreshStatusItemLabel() {
        guard let button = statusItem.button else { return }
        switch model.iconState {
        case .idle:
            button.title = "GN"
            button.image = NSImage(systemSymbolName: "bell", accessibilityDescription: "git-notified, no outstanding items")
        case .active(let n):
            button.title = "GN \(n)"
            button.image = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: "git-notified, \(n) outstanding items")
        case .setup:
            button.title = "GN ⚙"
            button.image = NSImage(systemSymbolName: "bell.badge.plus", accessibilityDescription: "git-notified, setup required")
        case .error:
            button.title = "GN !"
            button.image = NSImage(systemSymbolName: "bell.badge.fill", accessibilityDescription: "git-notified, error")
        }
    }
}

