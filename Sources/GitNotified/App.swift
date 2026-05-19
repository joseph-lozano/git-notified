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
        // Bell SF Symbol + "GN" identify the app; the title also carries a state
        // emoji + queue count when there's anything triage-worthy.
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
        iconObservation = model.$triageRows
            .combineLatest(model.$setup, model.$appCause)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in
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
            makePopoverOpaque()
        }
    }

    // NSPopover paints a vibrant translucent material behind its content. Walk up
    // from the content view to the popover's NSVisualEffectView host and switch
    // it to a window-background material so the dropdown reads as solid.
    private func makePopoverOpaque() {
        guard let contentView = popover.contentViewController?.view else { return }
        var v: NSView? = contentView.superview
        while let current = v {
            if let effect = current as? NSVisualEffectView {
                effect.material = .windowBackground
                effect.state = .active
                effect.isEmphasized = true
                break
            }
            v = current.superview
        }
    }

    private func refreshStatusItemLabel() {
        guard let button = statusItem.button else { return }
        switch model.iconState {
        case .loading:
            button.title = "GN 🔄"
            button.image = NSImage(systemSymbolName: "bell", accessibilityDescription: nil)
            button.setAccessibilityLabel("git-notified, checking…")
        case .idle:
            button.title = "GN 🎉"
            button.image = NSImage(systemSymbolName: "bell", accessibilityDescription: nil)
            button.setAccessibilityLabel("git-notified, inbox zero")
        case .active(let buckets):
            let segments = buckets.map { "\($0.state.menubarEmoji)\($0.count)" }
            button.title = "GN " + segments.joined(separator: " ")
            button.image = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: nil)
            let total = buckets.reduce(0) { $0 + $1.count }
            let breakdown = buckets.map { "\($0.count) \($0.state.label)" }.joined(separator: ", ")
            button.setAccessibilityLabel("git-notified, \(total) in queue: \(breakdown)")
        case .setup:
            button.title = "GN ⚙️"
            button.image = NSImage(systemSymbolName: "bell.badge.plus", accessibilityDescription: nil)
            button.setAccessibilityLabel("git-notified, setup required")
        case .error:
            button.title = "GN ⚠️"
            button.image = NSImage(systemSymbolName: "bell.badge.fill", accessibilityDescription: nil)
            button.setAccessibilityLabel("git-notified, error")
        }
    }
}

