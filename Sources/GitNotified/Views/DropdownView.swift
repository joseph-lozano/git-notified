import SwiftUI
import AppKit

struct DropdownView: View {
    @EnvironmentObject var model: AppModel
    @State private var showingManage: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showingManage {
                ManageReposView(isPresented: $showingManage)
            } else {
                mainContent
            }
        }
        .sheet(isPresented: $model.showingAddRepo) {
            AddRepositoryView()
                .environmentObject(model)
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if let cause = model.appCause {
            StatusBannerView(cause: cause)
                .padding(12)
            Divider()
        }
        if model.setup.pendingStep != nil {
            SetupChecklistView(setup: model.setup)
                .padding(12)
            Divider()
        } else {
            VStack(alignment: .leading, spacing: 14) {
                if !model.repoFailures.isEmpty {
                    RepoFailuresSection(failures: Array(model.repoFailures.values))
                    Divider()
                }
                ReviewsRequestedSection(rows: model.reviewRows)
                Divider()
                CIFailingSection(rows: model.ciFailingRows)
                Divider()
                ActivitySection(rows: model.activityRows)
            }
            .padding(12)
            Divider()
        }

        VStack(alignment: .leading, spacing: 6) {
            Button {
                model.toggleSilence()
            } label: {
                HStack {
                    Image(systemName: model.silenced ? "checkmark" : "bell.slash")
                    Text(model.silenced ? "Silenced — click to resume" : "Silence notifications")
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.silenced ? "Silenced, button, on" : "Silence notifications, button, off")
            .keyboardShortcut("s", modifiers: [.command])

            Divider()

            Button {
                model.showingAddRepo = true
            } label: {
                Label("Add repository…", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button {
                showingManage = true
            } label: {
                Label("Manage repositories…", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Divider()

            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .padding(12)

        Divider()
        FooterView()
            .padding(8)
    }
}

struct SetupChecklistView: View {
    let setup: SetupStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Setup").font(.headline)
            if setup.pendingStep == .ghNotReachable {
                checklistRow(
                    done: false,
                    label: "`gh` not found in this app's environment",
                    pending: true,
                    detail: "If gh is already installed (e.g. via Homebrew), the app may not see your shell's PATH when launched as a Login Item. See Troubleshooting."
                )
            } else {
                checklistRow(done: setup.ghReachable, label: "Install `gh`", pending: setup.pendingStep == .installGh, detail: setup.pendingStep == .installGh ? "Download from cli.github.com" : nil)
            }
            checklistRow(done: setup.signedIn, label: "Sign in with `gh auth login`", pending: setup.pendingStep == .signIn, detail: setup.pendingStep == .signIn ? "Run `gh auth login` in your terminal" : nil)
            checklistRow(done: setup.hasRepo, label: "Add a repository", pending: setup.pendingStep == .addRepo, detail: nil)
        }
    }

    @ViewBuilder
    private func checklistRow(done: Bool, label: String, pending: Bool, detail: String?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : (pending ? "circle.dashed" : "circle"))
                .foregroundColor(done ? .green : (pending ? .accentColor : .secondary))
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.subheadline)
                    .foregroundColor(done ? .secondary : .primary)
                if let detail {
                    Text(detail).font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
        }
    }
}

struct ReviewsRequestedSection: View {
    let rows: [DropdownRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Reviews requested").font(.headline)
                .accessibilityAddTraits(.isHeader)
            if rows.isEmpty {
                Text("No pending review requests.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(rows) { row in
                    RowView(row: row)
                }
            }
        }
    }
}

struct CIFailingSection: View {
    let rows: [DropdownRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CI failing").font(.headline)
                .accessibilityAddTraits(.isHeader)
            if rows.isEmpty {
                Text("No failing CI.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(rows) { row in
                    RowView(row: row)
                }
            }
        }
    }
}

struct StatusBannerView: View {
    @EnvironmentObject var model: AppModel
    let cause: AppCause

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(cause.message).font(.subheadline)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                actionButton
                if case .corruptedState = cause {
                    Button("Open folder") {
                        if let dir = try? Store.defaultDirectory() {
                            NSWorkspace.shared.open(dir)
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Status banner: \(cause.message)")
    }

    @ViewBuilder
    private var actionButton: some View {
        switch cause {
        case .notificationsDisabled:
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        case .corruptedState:
            Button("Reset state (you may receive notifications for recent events)") {
                model.resetCorruptedState()
            }
            .buttonStyle(.borderedProminent)
        default:
            Button("Retry now") {
                model.retryNow()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

struct RepoFailuresSection: View {
    @EnvironmentObject var model: AppModel
    let failures: [RepoFailure]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(failures, id: \.slug) { f in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.slug).font(.subheadline)
                        Text(f.copy).font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Remove") { model.removeRepo(slug: f.slug) }
                        .buttonStyle(.bordered)
                }
                .padding(.vertical, 2)
            }
        }
    }
}

struct ActivitySection: View {
    @EnvironmentObject var model: AppModel
    let rows: [DropdownRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("New comments & reviews").font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let banner = model.resumeBanner {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "bell.slash")
                    Text(banner.text).font(.caption)
                    Spacer()
                    Button {
                        model.resumeBanner = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .background(Color.accentColor.opacity(0.12))
                .cornerRadius(6)
            }
            if rows.isEmpty {
                Text("No recent activity in the last 24 hours.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(rows) { row in
                    RowView(row: row)
                }
            }
            Text("Showing activity from the last 24 hours.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.top, 2)
        }
    }
}

struct RowView: View {
    let row: DropdownRow

    var body: some View {
        Button {
            if let url = URL(string: row.url) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "arrow.up.right.square")
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(row.pr.displayRef) — \(row.pr.title)")
                        .font(.subheadline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text("\(row.summary) · \(row.age)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.pr.displayRef), \(row.pr.title), \(row.summary), \(row.age)")
        .accessibilityAddTraits(.isButton)
    }
}

struct FooterView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack {
            Text(footerText)
                .font(.caption2)
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private var footerText: String {
        if model.lastError != nil {
            return "Last check failed"
        }
        guard let date = model.lastCheckedAt else {
            return "Not checked yet"
        }
        return "Last checked \(Poller.ageString(from: date))"
    }
}
