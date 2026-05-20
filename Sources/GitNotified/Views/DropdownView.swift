import SwiftUI
import AppKit

struct DropdownView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            mainContent
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
            VStack(alignment: .leading, spacing: 0) {
                if let banner = model.resumeBanner {
                    ResumeBannerView(banner: banner)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                }
                TriageListView()
                    .padding(.vertical, 4)
            }
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

// MARK: - Triage queue

struct TriageListView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let rows = model.triageRows
        if rows.isEmpty {
            Text("You're all clear")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        } else {
            let yours = rows.filter { $0.role == .author }
            let reviews = rows.filter { $0.role == .reviewer }
            VStack(alignment: .leading, spacing: 0) {
                if !yours.isEmpty {
                    sectionHeader(title: "Yours", count: yours.count)
                    ForEach(yours) { TriageRowView(row: $0) }
                }
                if !reviews.isEmpty {
                    sectionHeader(title: "Reviews requested", count: reviews.count)
                    ForEach(reviews) { TriageRowView(row: $0) }
                }
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Text("\(count)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

struct TriageRowView: View {
    @EnvironmentObject var model: AppModel
    let row: TriageRow

    var body: some View {
        Button {
            if let url = URL(string: row.pr.url) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: row.state.glyph)
                    .font(.system(size: 12))
                    .foregroundColor(iconColor)
                    .frame(width: 14, alignment: .center)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.pr.title)
                        .font(.system(size: 13))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundColor(.primary)
                    Text("\(row.pr.displayRef) · \(row.state.label)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(row.age)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    diffSizeLine
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
        .contextMenu {
            Button("Open in browser") {
                if let url = URL(string: row.pr.url) { NSWorkspace.shared.open(url) }
            }
            Divider()
            Button("Hide this PR") {
                model.hidePR(id: row.id)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityLabel: String {
        var parts = ["\(row.pr.displayRef), \(row.pr.title), \(row.state.label), \(row.age)"]
        if let add = row.additions, let del = row.deletions {
            parts.append("+\(add), -\(del) lines")
        }
        return parts.joined(separator: ", ")
    }

    /// "+123 -45" colored green/red, rendered under the age in the right-hand column.
    /// `EmptyView` would force an `AnyView` wrapper, so we return an empty `Text` instead.
    private var diffSizeLine: Text {
        guard let add = row.additions, let del = row.deletions else { return Text("") }
        return Text("+\(add)").foregroundColor(.green)
            + Text(" ").foregroundColor(.secondary)
            + Text("-\(del)").foregroundColor(.red)
    }

    private var iconColor: Color {
        switch row.state {
        case .approved: return .green
        case .changesRequested: return .orange
        case .unansweredComment: return .gray
        case .ciFailing: return .red
        case .reviewRequested: return .blue
        case .waitingForReview: return .secondary
        }
    }
}

// MARK: - Resume banner, status banner, setup, footer

struct ResumeBannerView: View {
    @EnvironmentObject var model: AppModel
    let banner: ResumeBanner

    var body: some View {
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

struct FooterView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text(footerText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Button {
                model.retryNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
            .accessibilityLabel("Refresh now")
            Spacer()
            if model.hiddenCount > 0 {
                Button {
                    model.unhideAll()
                } label: {
                    Text("Show \(model.hiddenCount) hidden")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
            }
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
