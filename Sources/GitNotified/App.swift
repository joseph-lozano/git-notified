import SwiftUI
import AppKit

@main
struct GitNotifiedApp: App {
    @StateObject private var model: AppModel = {
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
            Image(systemName: "bell.badge.slash")
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
        }
    }
}
